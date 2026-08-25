import Darwin
import Foundation

struct ServicePreflightDependencies: @unchecked Sendable {
    let signatureVerifier: ServiceSignatureVerifier
    let validateModel: @Sendable (StandardPaths, ServiceConfiguration) async throws -> Void
    let validateForegroundStartup: @Sendable (URL, StandardPaths, ServiceConfiguration, Int) async throws -> Void
    let allocateProbePort: @Sendable () -> Int?
    let availableDiskBytes: @Sendable (URL) -> Int64?
    let portIsAvailable: @Sendable (Int) -> Bool
    let minimumFreeBytes: Int64

    init(
        signatureVerifier: ServiceSignatureVerifier,
        validateModel: @escaping @Sendable (StandardPaths, ServiceConfiguration) async throws -> Void,
        validateForegroundStartup: @escaping @Sendable (URL, StandardPaths, ServiceConfiguration, Int) async throws -> Void,
        availableDiskBytes: @escaping @Sendable (URL) -> Int64?,
        portIsAvailable: @escaping @Sendable (Int) -> Bool,
        allocateProbePort: @escaping @Sendable () -> Int? = allocateLoopbackProbePort,
        minimumFreeBytes: Int64 = 64 * 1024 * 1024
    ) {
        self.signatureVerifier = signatureVerifier
        self.validateModel = validateModel
        self.validateForegroundStartup = validateForegroundStartup
        self.allocateProbePort = allocateProbePort
        self.availableDiskBytes = availableDiskBytes
        self.portIsAvailable = portIsAvailable
        self.minimumFreeBytes = minimumFreeBytes
    }
}

struct ServicePreflightReport: Equatable, Sendable {
    let configuration: ServiceConfiguration
    let availableDiskBytes: Int64
    let modelValidated: Bool
    let executableValidated: Bool
}

struct ServicePreflight {
    let environment: [String: String]
    let paths: StandardPaths
    let servicePaths: ServicePaths
    let configurationOverride: ServiceConfiguration?
    let dependencies: ServicePreflightDependencies
    let fileSystem: ServiceFileSystem

    init(
        environment: [String: String],
        paths: StandardPaths,
        servicePaths: ServicePaths,
        configurationOverride: ServiceConfiguration? = nil,
        dependencies: ServicePreflightDependencies,
        fileSystem: ServiceFileSystem
    ) {
        self.environment = environment
        self.paths = paths
        self.servicePaths = servicePaths
        self.configurationOverride = configurationOverride
        self.dependencies = dependencies
        self.fileSystem = fileSystem
    }

    func run(allowOccupiedPort: Bool = false) async throws -> ServicePreflightReport {
        let configuration: ServiceConfiguration
        do {
            configuration = try configurationOverride ?? ServiceConfiguration.load(environment: environment)
        } catch {
            throw ServiceFailure(
                .configurationError,
                "configuration is invalid"
            )
        }

        try validateLayout()
        try preparePaths()
        try validateSecretSource()
        try validateExecutable()

        do {
            try await dependencies.signatureVerifier.verify(executable: servicePaths.executable)
        } catch {
            throw ServiceFailure(
                .signatureInvalid,
                "the executable signature is invalid or unverifiable"
            )
        }

        guard let available = dependencies.availableDiskBytes(servicePaths.serviceRoot),
              available >= dependencies.minimumFreeBytes
        else {
            throw ServiceFailure(
                .insufficientDisk,
                "available disk space is insufficient"
            )
        }

        if !allowOccupiedPort && !dependencies.portIsAvailable(configuration.port.value) {
            throw ServiceFailure(
                .portOccupied,
                "the service port is occupied"
            )
        }

        do {
            try await dependencies.validateModel(paths, configuration)
        } catch {
            throw ServiceFailure(
                .modelUnavailable,
                "the selected model is missing or corrupt",
                repairCommand: "syrinx models install --activate"
            )
        }

        guard let probePort = dependencies.allocateProbePort(),
              probePort != configuration.port.value,
              dependencies.portIsAvailable(probePort)
        else {
            throw ServiceFailure(.foregroundStartFailed, "a unique loopback probe port is unavailable")
        }
        do {
            try await dependencies.validateForegroundStartup(
                servicePaths.executable,
                paths,
                configuration,
                probePort
            )
        } catch {
            throw ServiceFailure(
                .foregroundStartFailed,
                "bounded foreground startup validation failed"
            )
        }

        return ServicePreflightReport(
            configuration: configuration,
            availableDiskBytes: available,
            modelValidated: true,
            executableValidated: true
        )
    }

    private func preparePaths() throws {
        try fileSystem.ensureDirectory(paths.data, privateMode: true)
        try fileSystem.ensureDirectory(paths.cache, privateMode: true)
        try fileSystem.ensureDirectory(paths.logs, privateMode: true)
        try fileSystem.ensureDirectory(servicePaths.serviceRoot, privateMode: true)
        try fileSystem.ensureDirectory(servicePaths.versionDirectory, privateMode: true)
        try fileSystem.ensureDirectory(servicePaths.launchAgentsDirectory, privateMode: false)

        for log in [servicePaths.stdoutLog, servicePaths.stderrLog] {
            if try fileSystem.exists(log) {
                try fileSystem.validateRegularFile(log, privateMode: true)
            }
        }
        if try fileSystem.exists(servicePaths.persistentConfiguration) {
            try fileSystem.validateRegularFile(servicePaths.persistentConfiguration, privateMode: true)
        }
        if try fileSystem.exists(servicePaths.plist) {
            try fileSystem.validateRegularFile(servicePaths.plist, privateMode: true)
            let plistText = try fileSystem.readExactPrivateFile(servicePaths.plist, limit: 256 * 1024)
            guard let plistData = plistText.data(using: .utf8),
                  let plist = try? PropertyListSerialization.propertyList(
                      from: plistData,
                      options: [],
                      format: nil
                  ) as? [String: Any],
                  plist["Label"] as? String == ServiceIdentity.label
            else {
                throw ServiceFileSystemError.malformedPlist
            }
        }
    }

    private func validateSecretSource() throws {
        if environment["SYRINX_API_KEY"] != nil {
            throw ServiceFailure(
                .invalidSecretSource,
                "a secret value cannot be copied into a LaunchAgent"
            )
        }
        if let source = environment["SYRINX_API_KEY_SOURCE"], source != "file" {
            throw ServiceFailure(.invalidSecretSource, "the secret source is invalid")
        }
        let rawPath = configurationOverride?.bearerSecretFile
            ?? (environment["SYRINX_API_KEY_SOURCE"] == "file"
                ? environment["SYRINX_API_KEY_FILE"]
                : nil)
        guard let rawPath else {
            if environment["SYRINX_API_KEY_SOURCE"] == "file" {
                throw ServiceFailure(.invalidSecretSource, "the secret source is invalid")
            }
            return
        }
        let url = URL(fileURLWithPath: rawPath)
        guard rawPath.hasPrefix("/"), !rawPath.contains("\0") else {
            throw ServiceFailure(.invalidSecretSource, "the secret source is invalid")
        }
        do {
            try fileSystem.validateSecretFile(url)
            let secretData = try fileSystem.readExactSecretData(url, limit: 16 * 1024)
            guard let secret = String(data: secretData, encoding: .utf8),
                  ServiceConfiguration.isValidBearerValue(secret)
            else {
                throw ServiceFileSystemError.readFailed
            }
        } catch {
            throw ServiceFailure(.invalidSecretSource, "the secret source is invalid")
        }
    }

    private func validateExecutable() throws {
        let executable = servicePaths.executable
        guard executable.isFileURL,
              executable.path.hasPrefix("/"),
              executable.standardizedFileURL.path == executable.path
        else { throw ServiceFailure(.unsafePath, "the executable path is unsafe") }

        do {
            try fileSystem.validateExecutableFile(executable)
        } catch {
            throw ServiceFailure(.unsafePath, "the executable path is unsafe")
        }
    }

    private func validateLayout() throws {
        let home = servicePaths.homeDirectory.standardizedFileURL
        let homeLibrary = home.appendingPathComponent("Library", isDirectory: true).standardizedFileURL.path
        let managedRoots = [paths.data, paths.cache, paths.logs, servicePaths.launchAgentsDirectory]

        guard home.path.hasPrefix("/"), home.path != "/" else {
            throw ServiceFailure(.unsafePath, "service paths are unsafe")
        }
        for root in managedRoots {
            guard root.isFileURL,
                  root.path.hasPrefix("/"),
                  root.path == root.standardizedFileURL.path,
                  root.path.hasPrefix(homeLibrary + "/")
            else {
                throw ServiceFailure(.unsafePath, "service paths are unsafe")
            }
        }

        let version = servicePaths.version
        guard !version.isEmpty,
              version != ".",
              version != "..",
              !version.contains("/"),
              !version.contains("\\"),
              servicePaths.serviceRoot.path.hasPrefix(paths.data.standardizedFileURL.path + "/"),
              servicePaths.versionDirectory.path.hasPrefix(servicePaths.serviceRoot.path + "/versions/"),
              servicePaths.persistentConfiguration.path.hasPrefix(paths.data.standardizedFileURL.path + "/"),
              servicePaths.configuration.path.hasPrefix(servicePaths.versionDirectory.path + "/"),
              servicePaths.plist.path.hasPrefix(servicePaths.launchAgentsDirectory.path + "/"),
              servicePaths.stdoutLog.path.hasPrefix(paths.logs.standardizedFileURL.path + "/"),
              servicePaths.stderrLog.path.hasPrefix(paths.logs.standardizedFileURL.path + "/")
        else {
            throw ServiceFailure(.unsafePath, "service paths are unsafe")
        }
    }
}

extension ServicePreflightDependencies {
    static func production(
        processRunner: any ServiceProcessRunner,
        environment: [String: String]
    ) -> ServicePreflightDependencies {
        let trustedHome = (try? StandardPaths.trustedCurrentUserHome())?.path
        let signatureVerifier = ServiceSignatureVerifier { executable in
            try await CodesignServiceSignatureVerifier(processRunner: processRunner)
                .verify(executable: executable)
        }
        return ServicePreflightDependencies(
            signatureVerifier: signatureVerifier,
            validateModel: { paths, configuration in
                try await validateProductionModel(paths: paths, configuration: configuration)
            },
            validateForegroundStartup: { executable, paths, configuration, probePort in
                let process = ForegroundServiceProcess(
                    executable: executable,
                    environment: controlledServiceEnvironment(
                        paths: paths,
                        configuration: configuration,
                        portOverride: probePort,
                        homeDirectory: trustedHome
                    )
                )
                try process.start()
                defer { process.stopAndReap() }
                let authorization = try configuredBearerSecret(
                    configuration,
                    fileSystem: ServiceFileSystem()
                )
                let health = await URLServiceHealthProbe().waitUntilReady(
                    port: probePort,
                    authorization: authorization,
                    timeout: .seconds(5)
                )
                guard health.state == .ready,
                      process.isRunning,
                      await verifiedPortOwner(
                          processRunner: processRunner,
                          port: probePort,
                          processID: process.processID
                      ) != nil
                else {
                    throw ServiceProcessError.launchFailed
                }
            },
            availableDiskBytes: { url in
                let attributes = try? FileManager.default.attributesOfFileSystem(forPath: url.path)
                return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
            },
            portIsAvailable: { port in
                guard let host = try? HostAddress("127.0.0.1"),
                      let value = try? Port(port)
                else { return false }
                return PortAvailability().check(host: host, port: value).available
            }
        )
    }
}

func validateProductionModel(
    paths: StandardPaths,
    configuration: ServiceConfiguration
) async throws {
    let lifecycle = try ModelLifecycleCoordinator(store: ModelStore(root: paths.data))
    guard configuration.modelID.value == lifecycle.manifest.modelId else {
        throw ModelLifecycleError.runtimeUnavailable
    }
    let lease = try await lifecycle.resolveRuntime()
    defer { lease.close() }
    guard lease.modelId == configuration.modelID.value,
          lease.modelId == lifecycle.manifest.modelId,
          lease.variantId == lifecycle.manifest.variantId,
          lease.immutableCommit == lifecycle.manifest.immutableCommit
    else {
        throw ModelLifecycleError.runtimeUnavailable
    }
}

func controlledServiceEnvironment(
    paths: StandardPaths,
    configuration: ServiceConfiguration,
    portOverride: Int? = nil,
    homeDirectory: String? = nil
) -> [String: String] {
    var result: [String: String] = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LC_ALL": "C",
        "HOME": homeDirectory ?? "/__syrinx_unavailable_authority__"
    ]
    result["SYRINX_HOST"] = configuration.host.value
    result["SYRINX_PORT"] = String(portOverride ?? configuration.port.value)
    result["SYRINX_MODEL_ID"] = configuration.modelID.value
    result["SYRINX_MAX_UPLOAD_BYTES"] = String(configuration.maxUploadBytes.value)
    result["SYRINX_MAX_ENVELOPE_BYTES"] = String(configuration.maxEnvelopeBytes.value)
    result["SYRINX_MAX_DURATION_SECONDS"] = String(configuration.maxDurationSeconds.value)
    result["SYRINX_MAX_JOBS"] = String(configuration.maxJobs.value)
    result["SYRINX_HTTP_IDLE_TIMEOUT_MILLISECONDS"] = String(configuration.httpIdleTimeoutMilliseconds.value)
    result["SYRINX_HTTP_REQUEST_TIMEOUT_MILLISECONDS"] = String(configuration.httpRequestTimeoutMilliseconds.value)
    result["SYRINX_HTTP_HEADER_FIELD_BYTES"] = String(configuration.httpHeaderFieldBytes.value)
    result["SYRINX_HTTP_HEADER_LIST_BYTES"] = String(configuration.httpHeaderListBytes.value)
    result["SYRINX_HTTP_HEADER_FIELD_COUNT"] = String(configuration.httpHeaderFieldCount.value)
    result["SYRINX_SHUTDOWN_TIMEOUT_SECONDS"] = String(configuration.shutdownTimeoutSeconds.value)
    if let secretFile = configuration.bearerSecretFile {
        result["SYRINX_API_KEY_SOURCE"] = "file"
        result["SYRINX_API_KEY_FILE"] = secretFile
    }
    return result
}

func configuredBearerSecret(
    _ configuration: ServiceConfiguration,
    fileSystem: ServiceFileSystem
) throws -> String? {
    if let secret = configuration.bearerSecret {
        guard ServiceConfiguration.isValidBearerValue(secret) else {
            throw ServiceFailure(.invalidSecretSource, "the secret source is invalid")
        }
        return secret
    }
    guard let rawPath = configuration.bearerSecretFile else { return nil }
    guard rawPath.hasPrefix("/"), !rawPath.contains("\0") else {
        throw ServiceFailure(.invalidSecretSource, "the secret source is invalid")
    }
    do {
        let data = try fileSystem.readExactSecretData(URL(fileURLWithPath: rawPath), limit: 16 * 1024)
        guard let secret = String(data: data, encoding: .utf8),
              ServiceConfiguration.isValidBearerValue(secret)
        else { throw ServiceFileSystemError.readFailed }
        return secret
    } catch let error as ServiceFailure {
        throw error
    } catch {
        throw ServiceFailure(.invalidSecretSource, "the secret source is invalid")
    }
}

private func allocateLoopbackProbePort() -> Int? {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { return nil }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    var result = sockaddr_in()
    let received = withUnsafeMutablePointer(to: &result) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(descriptor, $0, &length)
        }
    }
    guard received == 0 else { return nil }
    return Int(UInt16(bigEndian: result.sin_port))
}
