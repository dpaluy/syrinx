import Foundation

struct LaunchAgentError: Error, Equatable, Sendable {
    let operation: String
    let output: String
}

struct LaunchAgentStatus: Equatable, Sendable {
    let status: ServiceStatusKind
    let state: String?
    let processID: pid_t?
    let isLoaded: Bool
}

public struct ServiceConfigurationSnapshot: Codable, Equatable, Sendable {
    public let host: String
    public let port: Int
    public let modelID: String
    public let maxUploadBytes: Int
    public let maxEnvelopeBytes: Int
    public let maxDurationSeconds: Int
    public let maxJobs: Int
    public let httpIdleTimeoutMilliseconds: Int
    public let httpRequestTimeoutMilliseconds: Int
    public let httpHeaderFieldBytes: Int
    public let httpHeaderListBytes: Int
    public let httpHeaderFieldCount: Int
    public let shutdownTimeoutSeconds: Int
    public let bearerSecretFile: String?

    init(configuration: ServiceConfiguration) {
        host = configuration.host.value
        port = configuration.port.value
        modelID = configuration.modelID.value
        maxUploadBytes = configuration.maxUploadBytes.value
        maxEnvelopeBytes = configuration.maxEnvelopeBytes.value
        maxDurationSeconds = configuration.maxDurationSeconds.value
        maxJobs = configuration.maxJobs.value
        httpIdleTimeoutMilliseconds = configuration.httpIdleTimeoutMilliseconds.value
        httpRequestTimeoutMilliseconds = configuration.httpRequestTimeoutMilliseconds.value
        httpHeaderFieldBytes = configuration.httpHeaderFieldBytes.value
        httpHeaderListBytes = configuration.httpHeaderListBytes.value
        httpHeaderFieldCount = configuration.httpHeaderFieldCount.value
        shutdownTimeoutSeconds = configuration.shutdownTimeoutSeconds.value
        bearerSecretFile = configuration.bearerSecretFile
    }

    func makeConfiguration() throws -> ServiceConfiguration {
        try ServiceConfiguration(
            host: HostAddress(host),
            port: Port(port),
            modelID: ModelIdentifier(modelID),
            maxUploadBytes: ByteLimit(maxUploadBytes, key: "SYRINX_MAX_UPLOAD_BYTES"),
            maxEnvelopeBytes: ByteLimit(maxEnvelopeBytes, key: "SYRINX_MAX_ENVELOPE_BYTES"),
            maxDurationSeconds: DurationLimit(maxDurationSeconds, key: "SYRINX_MAX_DURATION_SECONDS"),
            maxJobs: JobLimit(maxJobs, key: "SYRINX_MAX_JOBS"),
            httpIdleTimeoutMilliseconds: DurationLimit(
                httpIdleTimeoutMilliseconds,
                key: "SYRINX_HTTP_IDLE_TIMEOUT_MILLISECONDS"
            ),
            httpRequestTimeoutMilliseconds: DurationLimit(
                httpRequestTimeoutMilliseconds,
                key: "SYRINX_HTTP_REQUEST_TIMEOUT_MILLISECONDS"
            ),
            httpHeaderFieldBytes: ByteLimit(
                httpHeaderFieldBytes,
                key: "SYRINX_HTTP_HEADER_FIELD_BYTES"
            ),
            httpHeaderListBytes: ByteLimit(
                httpHeaderListBytes,
                key: "SYRINX_HTTP_HEADER_LIST_BYTES"
            ),
            httpHeaderFieldCount: JobLimit(
                httpHeaderFieldCount,
                key: "SYRINX_HTTP_HEADER_FIELD_COUNT"
            ),
            shutdownTimeoutSeconds: ShutdownTimeout(
                shutdownTimeoutSeconds,
                key: "SYRINX_SHUTDOWN_TIMEOUT_SECONDS"
            ),
            bearerSecretFile: bearerSecretFile
        )
    }

    enum CodingKeys: String, CodingKey {
        case host
        case port
        case modelID = "model_id"
        case maxUploadBytes = "max_upload_bytes"
        case maxEnvelopeBytes = "max_envelope_bytes"
        case maxDurationSeconds = "max_duration_seconds"
        case maxJobs = "max_jobs"
        case httpIdleTimeoutMilliseconds = "http_idle_timeout_milliseconds"
        case httpRequestTimeoutMilliseconds = "http_request_timeout_milliseconds"
        case httpHeaderFieldBytes = "http_header_field_bytes"
        case httpHeaderListBytes = "http_header_list_bytes"
        case httpHeaderFieldCount = "http_header_field_count"
        case shutdownTimeoutSeconds = "shutdown_timeout_seconds"
        case bearerSecretFile = "bearer_secret_file"
    }
}

public enum ServicePlistBuilder {
    public static func make(
        configuration: ServiceConfiguration,
        paths: ServicePaths,
        configurationDigest: String? = nil
    ) -> String {
        let digest = (try? ServiceConfigurationDigest.forConfiguration(configuration)) ?? String(repeating: "0", count: 64)
        let environment: [(String, XMLValue)] = [
            ("SYRINX_CONFIG_PATH", .string(paths.configuration.path)),
            ("SYRINX_CONFIG_SHA256", .string(configurationDigest ?? digest)),
            ("SYRINX_HOST", .string(configuration.host.value)),
            ("SYRINX_MODEL_ID", .string(configuration.modelID.value)),
            ("SYRINX_PORT", .string(String(configuration.port.value))),
            ("SYRINX_SERVICE_LAUNCH", .string("1"))
        ]
        let values: [(String, XMLValue)] = [
            ("EnvironmentVariables", .dictionary(environment)),
            ("KeepAlive", .boolean(false)),
            ("Label", .string(ServiceIdentity.label)),
            ("LimitLoadToSessionType", .string("Aqua")),
            ("ProgramArguments", .array([.string(paths.executable.path), .string("serve")])),
            ("ProcessType", .string("Interactive")),
            ("RunAtLoad", .boolean(true)),
            ("StandardErrorPath", .string("/dev/null")),
            ("StandardOutPath", .string("/dev/null")),
            ("ThrottleInterval", .integer(30)),
            ("Umask", .integer(63)),
            ("WorkingDirectory", .string(paths.versionDirectory.path))
        ]
        let body = xmlDictionary(values, indent: 1)
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\">\n\(body)</plist>\n"
    }

    private enum XMLValue {
        case string(String)
        case integer(Int)
        case boolean(Bool)
        case array([XMLValue])
        case dictionary([(String, XMLValue)])
    }

    private static func xmlDictionary(_ values: [(String, XMLValue)], indent: Int) -> String {
        let sorted = values.sorted { $0.0 < $1.0 }
        let padding = String(repeating: "  ", count: indent)
        let innerPadding = String(repeating: "  ", count: indent + 1)
        let contents = sorted.map { key, value in
            "\(innerPadding)<key>\(escape(key))</key>\n\(xml(value, indent: indent + 1))"
        }.joined(separator: "\n")
        return "\(padding)<dict>\n\(contents)\n\(padding)</dict>\n"
    }

    private static func xml(_ value: XMLValue, indent: Int) -> String {
        let padding = String(repeating: "  ", count: indent)
        switch value {
        case let .string(value):
            return "\(padding)<string>\(escape(value))</string>"
        case let .integer(value):
            return "\(padding)<integer>\(value)</integer>"
        case let .boolean(value):
            return "\(padding)<\(value ? "true" : "false")/>"
        case let .array(values):
            let items = values.map { xml($0, indent: indent + 1) }.joined(separator: "\n")
            return "\(padding)<array>\n\(items)\n\(padding)</array>"
        case let .dictionary(values):
            return xmlDictionary(values, indent: indent)
        }
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

struct LaunchAgentManager: Sendable {
    private static let stableAbsenceObservationCount = 10
    private static let stableAbsencePollInterval: Duration = .milliseconds(50)

    let paths: ServicePaths
    let processRunner: any ServiceProcessRunner
    let fileSystem: ServiceFileSystem
    let uid: uid_t

    init(
        paths: ServicePaths,
        processRunner: any ServiceProcessRunner,
        fileSystem: ServiceFileSystem = .init(),
        uid: uid_t = getuid()
    ) {
        self.paths = paths
        self.processRunner = processRunner
        self.fileSystem = fileSystem
        self.uid = uid
    }

    func install(plist: String, start: Bool = true) async throws {
        try fileSystem.writePrivateFileAtomically(Data(plist.utf8), to: paths.plist)
        _ = try validateInstalledPlistIfPresent()
        guard start else { return }
        do {
            let result = try await run(["bootstrap", domain, paths.plist.path])
            if result.exitCode != 0 {
                throw LaunchAgentError(operation: "bootstrap", output: redacted(result))
            }
        } catch let error as LaunchAgentError {
            throw error
        } catch let error as ServiceProcessError {
            if error == .cancelled {
                throw error
            }
            throw LaunchAgentError(operation: "bootstrap", output: "launchctl failed")
        } catch {
            throw LaunchAgentError(operation: "bootstrap", output: "launchctl failed")
        }
        if start {
            _ = try await waitForLoaded(timeout: .seconds(10))
            try await kickstart()
        }
    }

    func start() async throws {
        guard try validateInstalledPlistIfPresent() else {
            throw LaunchAgentError(operation: "start", output: "service is not installed")
        }
        let current = try await status()
        switch current.status {
        case .ready, .starting:
            return
        case .stopped:
            if !current.isLoaded {
                let bootstrap = try await run(["bootstrap", domain, paths.plist.path])
                guard bootstrap.exitCode == 0 else {
                    throw LaunchAgentError(operation: "bootstrap", output: redacted(bootstrap))
                }
                _ = try await waitForLoaded(timeout: .seconds(10))
            }
        case .notInstalled, .unknown, .unhealthy:
            throw LaunchAgentError(operation: "start", output: "service state is not trusted")
        }
        try await kickstart()
    }

    private func kickstart() async throws {
        let result = try await run(["kickstart", "-k", serviceTarget])
        guard result.exitCode == 0 else {
            throw LaunchAgentError(operation: "start", output: redacted(result))
        }
    }

    func waitForLoaded(timeout: Duration) async throws -> LaunchAgentStatus {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            let current = try await status()
            if current.isLoaded { return current }
            guard ContinuousClock.now < deadline else {
                throw LaunchAgentError(operation: "status", output: "service did not publish")
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    func waitForReady(timeout: Duration) async throws -> LaunchAgentStatus {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            let current = try await status()
            if current.status == .ready { return current }
            guard current.status == .starting, current.isLoaded else {
                throw LaunchAgentError(operation: "status", output: "service is not ready")
            }
            guard ContinuousClock.now < deadline else {
                throw LaunchAgentError(operation: "status", output: "service did not become ready")
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    func waitForLoadedStopped(timeout: Duration) async throws -> LaunchAgentStatus {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            let current = try await status()
            if current.status == .stopped, current.isLoaded {
                return current
            }
            guard current.isLoaded, current.status == .starting || current.status == .ready else {
                throw LaunchAgentError(operation: "stop", output: "service did not remain loaded")
            }
            guard ContinuousClock.now < deadline else {
                throw LaunchAgentError(operation: "stop", output: "service did not stop")
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    func waitForStableAbsence(
        timeout: Duration,
        observations: Int = LaunchAgentManager.stableAbsenceObservationCount
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var absentObservations = 0
        while true {
            try Task.checkCancellation()
            let current = try await status()
            if current.isLoaded {
                guard current.status == .ready || current.status == .starting || current.status == .stopped else {
                    throw LaunchAgentError(operation: "status", output: "loaded service identity is not proven")
                }
                try await stop()
                absentObservations = 0
            } else if current.status == .notInstalled || current.status == .stopped {
                absentObservations += 1
                if absentObservations >= observations {
                    return
                }
            } else {
                throw LaunchAgentError(operation: "status", output: "service absence is not proven")
            }
            guard ContinuousClock.now < deadline else {
                throw LaunchAgentError(operation: "status", output: "service absence was not stable")
            }
            try await Task.sleep(for: LaunchAgentManager.stableAbsencePollInterval)
        }
    }

    func restart() async throws {
        try await start()
    }

    func restore(plist: String, priorStatus: LaunchAgentStatus) async throws {
        try fileSystem.writePrivateFileAtomically(Data(plist.utf8), to: paths.plist)
        _ = try validateInstalledPlistIfPresent()
        guard priorStatus.isLoaded else { return }

        let bootstrap = try await run(["bootstrap", domain, paths.plist.path])
        guard bootstrap.exitCode == 0 else {
            throw LaunchAgentError(operation: "bootstrap", output: redacted(bootstrap))
        }
        let published = try await waitForLoaded(
            timeout: ServiceRecoveryContext.timeout(default: .seconds(10))
        )

        switch priorStatus.status {
        case .ready, .starting:
            try await kickstart()
        case .stopped:
            if published.status != .stopped {
                try await stopKeepingLoaded()
            } else {
                _ = try await waitForLoadedStopped(
                    timeout: ServiceRecoveryContext.timeout(default: .seconds(10))
                )
            }
        default:
            throw LaunchAgentError(operation: "restore", output: "prior service state is not restorable")
        }
    }

    func stopKeepingLoaded() async throws {
        guard try validateInstalledDefinitionIfPresent() else {
            throw LaunchAgentError(operation: "stop", output: "managed service definition is missing")
        }
        let current = try await status()
        guard current.isLoaded else {
            throw LaunchAgentError(operation: "stop", output: "service is not loaded")
        }
        if current.status == .stopped {
            _ = try await waitForLoadedStopped(
                timeout: ServiceRecoveryContext.timeout(default: .seconds(10))
            )
            return
        }
        guard current.status == .ready || current.status == .starting else {
            throw LaunchAgentError(operation: "stop", output: "loaded service identity is not proven")
        }
        let result = try await run(["kill", "SIGTERM", serviceTarget])
        guard result.exitCode == 0 || result.exitCode == 3 || result.exitCode == 113 else {
            throw LaunchAgentError(operation: "kill", output: redacted(result))
        }
        _ = try await waitForLoadedStopped(
            timeout: ServiceRecoveryContext.timeout(default: .seconds(10))
        )
    }

    func stop() async throws {
        guard try validateInstalledDefinitionIfPresent() else {
            throw LaunchAgentError(operation: "stop", output: "managed service definition is missing")
        }
        let current = try await status()
        switch current.status {
        case .stopped where !current.isLoaded:
            return
        case .ready, .starting, .stopped:
            guard current.isLoaded else {
                throw LaunchAgentError(operation: "stop", output: "loaded service state is not trusted")
            }
        case .notInstalled, .unknown, .unhealthy:
            throw LaunchAgentError(operation: "stop", output: "loaded service identity is not proven")
        }
        let result = try await run(["bootout", serviceTarget])
        guard result.exitCode == 0 || result.exitCode == 3 || result.exitCode == 113 else {
            throw LaunchAgentError(operation: "stop", output: redacted(result))
        }
    }

    func removePlist() throws {
        _ = try validateInstalledPlistIfPresent()
        try fileSystem.removeTreeIfPresent(paths.plist)
    }

    func status() async throws -> LaunchAgentStatus {
        var hasPlist = false
        var trustedPlist = true
        var expectedDefinition: ManagedLaunchDefinition?
        do {
            hasPlist = try validateInstalledPlistIfPresent()
            if hasPlist {
                let plist = try fileSystem.readExactPrivateFile(paths.plist, limit: 256 * 1024)
                let configurationData = try fileSystem.readExactPrivateData(
                    paths.configuration,
                    limit: 512 * 1024
                )
                let configuration = try ServiceConfiguration.load(configurationData: configurationData)
                expectedDefinition = try managedDefinition(
                    from: plist,
                    configurationDigest: ServiceConfigurationDigest.forData(configurationData),
                    configuration: configuration
                )
            }
        } catch {
            trustedPlist = false
        }
        let result = try await run(["print", serviceTarget])
        if result.exitCode == 3 || result.exitCode == 113 {
            return LaunchAgentStatus(
                status: trustedPlist && hasPlist ? .stopped : trustedPlist ? .notInstalled : .unknown,
                state: nil,
                processID: nil,
                isLoaded: false
            )
        }
        guard result.exitCode == 0 else {
            return LaunchAgentStatus(status: .unknown, state: redacted(result), processID: nil, isLoaded: false)
        }
        guard trustedPlist, hasPlist else {
            return LaunchAgentStatus(
                status: .unknown,
                state: "managed service plist is missing or untrusted",
                processID: nil,
                isLoaded: true
            )
        }
        let output = (result.stdout + "\n" + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let expectedDefinition,
              let definition = parseLaunchctlDefinition(output),
              launchctlDefinitionMatches(definition, expected: expectedDefinition)
        else {
            return LaunchAgentStatus(
                status: .unknown,
                state: "loaded service identity is not proven",
                processID: nil,
                isLoaded: true
            )
        }
        let processID = definition.fields["pid"].flatMap { Int32($0) }.flatMap { $0 > 0 ? $0 : nil }
        let pair = (definition.fields["state"] ?? "", definition.fields["job state"] ?? "")
        switch pair {
        case ("running", "running"):
            return LaunchAgentStatus(status: .ready, state: redactedText(output), processID: processID, isLoaded: true)
        case ("starting", "starting"), ("starting", "running"):
            return LaunchAgentStatus(status: .starting, state: redactedText(output), processID: processID, isLoaded: true)
        case ("not running", "exited"), ("exited", "exited"), ("stopped", "stopped"), ("stopped", "exited"):
            return LaunchAgentStatus(status: .stopped, state: redactedText(output), processID: nil, isLoaded: true)
        default:
            return LaunchAgentStatus(status: .unknown, state: redactedText(output), processID: nil, isLoaded: true)
        }
    }

    func readLogs() throws -> String {
        _ = try validateInstalledPlistIfPresent()
        var sections: [String] = []
        for (name, url) in [("stdout", paths.stdoutLog), ("stderr", paths.stderrLog)] {
            guard try fileSystem.exists(url) else { continue }
            let text = try fileSystem.readBoundedLogFile(url, limit: 32 * 1024)
            sections.append("[\(name)]\n\(text)")
        }
        return ServiceRedactor.redact(sections.joined(separator: "\n"), paths: [paths.homeDirectory])
    }

    func validateInstalledPlistIfPresent() throws -> Bool {
        guard try fileSystem.validateRegularFileIfPresent(paths.plist, privateMode: true) else {
            return false
        }
        let value = try fileSystem.readExactPrivateFile(paths.plist, limit: 256 * 1024)
        try validatePlist(value)
        return true
    }

    func validateInstalledDefinitionIfPresent() throws -> Bool {
        guard try validateInstalledPlistIfPresent() else { return false }
        let plist = try fileSystem.readExactPrivateFile(paths.plist, limit: 256 * 1024)
        let configurationData = try fileSystem.readExactPrivateData(
            paths.configuration,
            limit: 512 * 1024
        )
        let configuration = try ServiceConfiguration.load(configurationData: configurationData)
        _ = try managedDefinition(
            from: plist,
            configurationDigest: ServiceConfigurationDigest.forData(configurationData),
            configuration: configuration
        )
        return true
    }

    private var domain: String { "gui/\(uid)" }
    private var serviceTarget: String { "\(domain)/\(ServiceIdentity.label)" }

    private func run(_ arguments: [String]) async throws -> ServiceProcessResult {
        do {
            try ServiceRecoveryContext.consume()
            let result = try await processRunner.run(
                executable: URL(fileURLWithPath: "/bin/launchctl"),
                arguments: arguments,
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"],
                timeout: ServiceRecoveryContext.timeout(default: .seconds(10))
            )
            try ServiceRecoveryContext.consume()
            return result
        } catch is CancellationError {
            throw ServiceProcessError.cancelled
        } catch is ServiceRecoveryError {
            throw ServiceRecoveryError.budgetExceeded
        } catch let error as ServiceProcessError {
            if error == .cancelled {
                throw error
            }
            throw LaunchAgentError(operation: arguments.first ?? "launchctl", output: "launchctl failed")
        } catch {
            throw LaunchAgentError(operation: arguments.first ?? "launchctl", output: "launchctl failed")
        }
    }

    private func redacted(_ result: ServiceProcessResult) -> String {
        ServiceRedactor.redact(result.stdout + "\n" + result.stderr, paths: [paths.homeDirectory])
    }

    private func redactedText(_ value: String) -> String {
        ServiceRedactor.redact(value, paths: [paths.homeDirectory])
    }

    private func validatePlist(_ value: String) throws {
        guard let data = value.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: Any]
        else { throw invalidPlist() }

        let expectedKeys: Set<String> = [
            "EnvironmentVariables", "KeepAlive", "Label", "LimitLoadToSessionType",
            "ProgramArguments", "ProcessType", "RunAtLoad", "StandardErrorPath",
            "StandardOutPath", "ThrottleInterval", "Umask", "WorkingDirectory"
        ]
        guard Set(plist.keys) == expectedKeys,
              plist["Label"] as? String == ServiceIdentity.label,
              plist["LimitLoadToSessionType"] as? String == "Aqua",
              plist["ProcessType"] as? String == "Interactive",
              (plist["RunAtLoad"] as? NSNumber)?.boolValue == true,
              (plist["ThrottleInterval"] as? NSNumber)?.intValue == 30,
              (plist["Umask"] as? NSNumber)?.intValue == 63,
              plist["StandardOutPath"] as? String == "/dev/null",
              plist["StandardErrorPath"] as? String == "/dev/null",
              plist["WorkingDirectory"] as? String == paths.versionDirectory.path,
              (plist["ProgramArguments"] as? [String]) == [paths.executable.path, "serve"]
        else { throw invalidPlist() }

        guard (plist["KeepAlive"] as? NSNumber)?.boolValue == false
        else { throw invalidPlist() }

        guard let environment = plist["EnvironmentVariables"] as? [String: Any],
              Set(environment.keys) == [
                  "SYRINX_CONFIG_PATH", "SYRINX_CONFIG_SHA256", "SYRINX_HOST", "SYRINX_MODEL_ID",
                  "SYRINX_PORT", "SYRINX_SERVICE_LAUNCH"
              ],
              environment.values.allSatisfy({ $0 is String }),
              environment["SYRINX_CONFIG_PATH"] as? String == paths.configuration.path,
              (environment["SYRINX_CONFIG_SHA256"] as? String).map(ServiceConfigurationDigest.isValid) == true,
              environment["SYRINX_HOST"] as? String == "127.0.0.1",
              let model = environment["SYRINX_MODEL_ID"] as? String,
              (try? ModelIdentifier(model)) != nil,
              let portText = environment["SYRINX_PORT"] as? String,
              let port = Int(portText),
              (try? Port(port)) != nil,
              environment["SYRINX_SERVICE_LAUNCH"] as? String == "1"
        else { throw invalidPlist() }
    }

    private struct ManagedLaunchDefinition: Sendable {
        let program: String
        let arguments: [String]
        let workingDirectory: String
        let environment: [String: String]
        let spawnType: String
        let minimumRuntime: String
        let baseMinimumRuntime: String
        let properties: String
    }

    private struct ParsedLaunchctlDefinition: Sendable {
        let fields: [String: String]
        let arguments: [String]
        let environment: [String: String]
    }

    private func managedDefinition(
        from value: String,
        configurationDigest: String,
        configuration: ServiceConfiguration
    ) throws -> ManagedLaunchDefinition {
        guard ServiceConfigurationDigest.isValid(configurationDigest),
              let data = value.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String],
              let program = arguments.first,
              let workingDirectory = plist["WorkingDirectory"] as? String,
              let environmentValue = plist["EnvironmentVariables"] as? [String: Any]
        else { throw invalidPlist() }
        let environment = try environmentValue.reduce(into: [String: String]()) { result, item in
            guard let value = item.value as? String else { throw invalidPlist() }
            result[item.key] = value
        }
        guard environment["SYRINX_CONFIG_SHA256"] == configurationDigest else {
            throw invalidPlist()
        }
        guard environment["SYRINX_HOST"] == configuration.host.value,
              environment["SYRINX_MODEL_ID"] == configuration.modelID.value,
              environment["SYRINX_PORT"] == String(configuration.port.value)
        else {
            throw invalidPlist()
        }
        var expectedEnvironment = environment
        expectedEnvironment["OSLogRateLimit"] = "64"
        expectedEnvironment["XPC_SERVICE_NAME"] = ServiceIdentity.label
        return ManagedLaunchDefinition(
            program: program,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: expectedEnvironment,
            spawnType: "interactive (4)",
            minimumRuntime: "30",
            baseMinimumRuntime: "30",
            properties: "runatload | inferred program"
        )
    }

    private func launchctlDefinitionMatches(
        _ definition: ParsedLaunchctlDefinition,
        expected: ManagedLaunchDefinition
    ) -> Bool {
        let fields = definition.fields
        guard fields["path"] == paths.plist.path,
              fields["type"] == "LaunchAgent",
              fields["program"] == expected.program,
              fields["working directory"] == expected.workingDirectory,
              fields["stdout path"] == "/dev/null",
              fields["stderr path"] == "/dev/null",
              fields["spawn type"] == expected.spawnType,
              fields["properties"] == expected.properties,
              let state = fields["state"],
              let jobState = fields["job state"],
              supportedStatePair(state: state, jobState: jobState),
              let domainValue = fields["domain"],
              domainValue.hasPrefix("\(domain) ["),
              domainValue.hasSuffix("]"),
              domainValue.dropFirst("\(domain) [".count).dropLast().allSatisfy(\.isNumber),
              definition.arguments == expected.arguments,
              definition.environment == expected.environment
        else { return false }
        if let minimumRuntime = fields["minimum runtime"], minimumRuntime != expected.minimumRuntime {
            return false
        }
        if let baseMinimumRuntime = fields["base minimum runtime"], baseMinimumRuntime != expected.baseMinimumRuntime {
            return false
        }
        return true
    }

    private func supportedStatePair(state: String, jobState: String) -> Bool {
        switch (state, jobState) {
        case ("running", "running"),
             ("starting", "starting"),
             ("starting", "running"),
             ("not running", "exited"),
             ("exited", "exited"),
             ("stopped", "stopped"),
             ("stopped", "exited"):
            return true
        default:
            return false
        }
    }

    private func parseLaunchctlDefinition(_ output: String) -> ParsedLaunchctlDefinition? {
        let lines = output.split(whereSeparator: \.isNewline).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard lines.first == "\(domain)/\(ServiceIdentity.label) = {" else { return nil }

        let requiredTopLevelFields: Set<String> = [
            "path", "type", "program", "working directory", "stdout path", "stderr path",
            "spawn type", "properties", "state", "job state", "domain"
        ]
        let observedTopLevelFields = requiredTopLevelFields.union([
            "pid", "minimum runtime", "base minimum runtime"
        ])
        var fields: [String: String] = [:]
        var arguments: [String]?
        var environment: [String: String]?
        var seenSections = Set<String>()
        var depth = 1
        var index = 1
        var closed = false

        while index < lines.count {
            let line = lines[index]
            if line == "}" {
                depth = 0
                closed = true
                index += 1
                break
            }
            if line == "arguments = {" {
                guard seenSections.insert("arguments").inserted,
                      let section = parseDirectSection(lines: lines, start: index),
                      let values = section.values
                else { return nil }
                arguments = values
                index = section.nextIndex
                continue
            }
            if line == "environment = {" {
                guard seenSections.insert("environment").inserted,
                      let section = parseDirectSection(lines: lines, start: index),
                      let sectionValues = section.values,
                      let values = parseEnvironmentValues(sectionValues)
                else { return nil }
                environment = values
                index = section.nextIndex
                continue
            }
            if line.hasSuffix(" = {") {
                guard let next = skipBlock(lines: lines, start: index) else { return nil }
                index = next
                continue
            }
            if let separator = line.range(of: " = ") {
                let name = String(line[..<separator.lowerBound])
                let value = String(line[separator.upperBound...])
                if observedTopLevelFields.contains(name) {
                    guard fields[name] == nil else { return nil }
                    fields[name] = value
                }
            }
            index += 1
        }

        guard closed, depth == 0, index == lines.count,
              let arguments, let environment
        else { return nil }
        return ParsedLaunchctlDefinition(fields: fields, arguments: arguments, environment: environment)
    }

    private func parseDirectSection(
        lines: [String],
        start: Int
    ) -> (values: [String]?, nextIndex: Int)? {
        var depth = 0
        var values: [String] = []
        for index in start..<lines.count {
            let line = lines[index]
            let before = depth
            depth += braceDelta(line)
            if index == start { continue }
            if before == 1, depth == 1, !line.isEmpty {
                values.append(stripQuotes(line))
            }
            if depth == 0 {
                return (values, index + 1)
            }
            guard depth > 0 else { return nil }
        }
        return nil
    }

    private func parseEnvironmentValues(_ values: [String]) -> [String: String]? {
        var result: [String: String] = [:]
        for value in values {
            let parts = value.components(separatedBy: "=>")
            guard parts.count == 2 else { return nil }
            let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let content = stripQuotes(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
            guard !name.isEmpty, result[name] == nil else { return nil }
            result[name] = content
        }
        return result
    }

    private func skipBlock(lines: [String], start: Int) -> Int? {
        var depth = 0
        for index in start..<lines.count {
            depth += braceDelta(lines[index])
            if depth == 0 { return index + 1 }
            guard depth > 0 else { return nil }
        }
        return nil
    }

    private func braceDelta(_ line: String) -> Int {
        line.reduce(into: 0) { result, character in
            if character == "{" { result += 1 }
            if character == "}" { result -= 1 }
        }
    }

    private func stripQuotes(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private func invalidPlist() -> LaunchAgentError {
        LaunchAgentError(operation: "plist", output: "invalid service plist")
    }
}

enum ServiceRedactor {
    static func redactLog(_ text: String, paths: [URL] = []) -> String {
        var result = text
        for path in paths.map(\.path) where !path.isEmpty {
            result = result.replacingOccurrences(of: path, with: "<redacted>")
        }
        guard let regex = try? NSRegularExpression(
            pattern: "(?i)Bearer[ \\t]+[^\\r\\n \\t]+"
        ) else { return result }
        let range = NSRange(result.startIndex..., in: result)
        return regex.stringByReplacingMatches(
            in: result,
            range: range,
            withTemplate: "Bearer <redacted>"
        )
    }

    static func redact(_ text: String, paths: [URL] = []) -> String {
        var result = text
        for path in paths.map(\.path) where !path.isEmpty {
            result = result.replacingOccurrences(of: path, with: "<redacted>")
        }
        if let regex = try? NSRegularExpression(pattern: "/[^\\s\"']+") {
            let range = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, range: range).reversed()
            for match in matches {
                guard let swiftRange = Range(match.range, in: result) else { continue }
                result.replaceSubrange(swiftRange, with: "<redacted>")
            }
        }
        let words = result.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        var redactedWords: [String] = []
        var redactNext = false
        for word in words {
            if redactNext {
                redactedWords.append("<redacted>")
                redactNext = false
            } else {
                let string = String(word)
                redactedWords.append(string)
                redactNext = string.lowercased() == "bearer"
            }
        }
        return redactedWords.joined(separator: " ").prefix(64 * 1024).description
    }
}
