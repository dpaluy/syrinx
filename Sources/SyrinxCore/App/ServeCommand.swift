import Foundation

protocol ServeEngine: HTTPTranscriptionHandler, Sendable {
    var isReady: Bool { get async }
    func start() async throws
    func drain(timeout: Duration) async -> DrainResult
}

extension NativeTranscriptionEngine: ServeEngine {}

protocol ServeHTTPService: Sendable {
    func run() async throws
    func beginDrain() async
    func waitForHTTPDrain() async -> Bool
}

extension SyrinxHTTPService: ServeHTTPService {}

public struct ServeCommand: Sendable {
    public static let usage = "usage: syrinx serve\n"

    private let environment: [String: String]
    private let paths: StandardPaths
    private let engineFactory: @Sendable (ServiceConfiguration, StandardPaths) throws -> any ServeEngine
    private let serviceFactory: @Sendable (
        HTTPServiceConfiguration,
        any HTTPTranscriptionHandler,
        ReadinessSource
    ) -> any ServeHTTPService

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        paths: StandardPaths = .init()
    ) {
        self.environment = environment
        self.paths = paths
        self.engineFactory = { configuration, paths in
            try NativeTranscriptionEngine(configuration: configuration, paths: paths)
        }
        self.serviceFactory = { configuration, handler, readiness in
            SyrinxHTTPService(configuration: configuration, handler: handler, readiness: readiness)
        }
    }

    init(
        environment: [String: String],
        paths: StandardPaths,
        engineFactory: @escaping @Sendable (ServiceConfiguration, StandardPaths) throws -> any ServeEngine,
        serviceFactory: @escaping @Sendable (
            HTTPServiceConfiguration,
            any HTTPTranscriptionHandler,
            ReadinessSource
        ) -> any ServeHTTPService
    ) {
        self.environment = environment
        self.paths = paths
        self.engineFactory = engineFactory
        self.serviceFactory = serviceFactory
    }

    public func run(arguments: [String]) async -> CommandResult {
        guard arguments.isEmpty else {
            return CommandResult(exitCode: 2, stderr: Self.usage)
        }

        let logWriter = ServiceLogWriter(
            paths: [
                paths.logs.appendingPathComponent("service.stdout.log", isDirectory: false),
                paths.logs.appendingPathComponent("service.stderr.log", isDirectory: false)
            ]
        )
        try? logWriter.prepare()
        let result = await runWithLogWriter(logWriter)
        return result
    }

    private func runWithLogWriter(_ logWriter: ServiceLogWriter) async -> CommandResult {
        try? logWriter.append("serve_start")
        defer { try? logWriter.append("serve_exit") }

        let configuration: ServiceConfiguration
        do {
            configuration = try loadConfiguration()
            try paths.validate()
        } catch {
            try? logWriter.append(
                "serve_rejected configuration_error",
                to: paths.logs.appendingPathComponent("service.stderr.log", isDirectory: false)
            )
            return failure(code: "configuration_error")
        }

        let engine: any ServeEngine
        do {
            engine = try engineFactory(configuration, paths)
        } catch {
            try? logWriter.append(
                "serve_rejected runtime_unavailable",
                to: paths.logs.appendingPathComponent("service.stderr.log", isDirectory: false)
            )
            return failure(code: "runtime_unavailable")
        }

        let coordinator = ServiceCoordinator(
            configuration: configuration,
            engine: engine,
            serviceFactory: serviceFactory
        )
        return await coordinator.run()
    }

    private func failure(code: String) -> CommandResult {
        CommandResult(exitCode: 1, stderr: "serve_failed: \(code)\n")
    }

    private func loadConfiguration() throws -> ServiceConfiguration {
        let fileSystem = ServiceFileSystem()
        let hasDirectSecretEnvironment = environment["SYRINX_API_KEY"] != nil
            || environment["SYRINX_API_KEY_SOURCE"] != nil
            || environment["SYRINX_API_KEY_FILE"] != nil
        let serviceLaunchMarker = environment["SYRINX_SERVICE_LAUNCH"]
        guard serviceLaunchMarker == nil || serviceLaunchMarker == "1" else {
            throw ConfigurationError.invalidValue(
                key: "SYRINX_SERVICE_LAUNCH",
                value: "redacted",
                reason: "must be 1"
            )
        }
        let isServiceLaunch = serviceLaunchMarker == "1"
        let configuration: ServiceConfiguration
        if let rawPath = environment["SYRINX_CONFIG_PATH"] {
            guard !hasDirectSecretEnvironment else {
                throw ConfigurationError.invalidValue(
                    key: "SYRINX_API_KEY",
                    value: "redacted",
                    reason: "direct secret settings cannot be combined with a versioned configuration"
                )
            }
            guard rawPath.hasPrefix("/"), !rawPath.contains("\0") else {
                throw ConfigurationError.invalidValue(
                    key: "SYRINX_CONFIG_PATH",
                    value: "redacted",
                    reason: "must be an absolute private configuration path"
                )
            }
            let data = try fileSystem.readExactPrivateData(
                URL(fileURLWithPath: rawPath),
                limit: 512 * 1024
            )
            if isServiceLaunch {
                guard let rawDigest = environment["SYRINX_CONFIG_SHA256"],
                      ServiceConfigurationDigest.isValid(rawDigest),
                      ServiceConfigurationDigest.forData(data) == rawDigest
                else {
                    throw ConfigurationError.invalidValue(
                        key: "SYRINX_CONFIG_SHA256",
                        value: "redacted",
                        reason: "does not match the private service configuration"
                    )
                }
            }
            configuration = try ServiceConfiguration.load(configurationData: data)
        } else {
            guard !isServiceLaunch else {
                throw ConfigurationError.invalidValue(
                    key: "SYRINX_CONFIG_PATH",
                    value: "redacted",
                    reason: "service launch requires a versioned configuration"
                )
            }
            configuration = try ServiceConfiguration.load(environment: environment)
        }

        guard let rawSecretPath = configuration.bearerSecretFile else {
            return configuration
        }
        guard rawSecretPath.hasPrefix("/"), !rawSecretPath.contains("\0") else {
            throw ConfigurationError.invalidValue(
                key: "bearer_secret_file",
                value: "redacted",
                reason: "must be an absolute private secret path"
            )
        }
        let secretData = try fileSystem.readExactSecretData(
            URL(fileURLWithPath: rawSecretPath),
            limit: 16 * 1024
        )
        guard let secret = String(data: secretData, encoding: .utf8),
              ServiceConfiguration.isValidBearerValue(secret)
        else {
            throw ConfigurationError.invalidValue(
                key: "bearer_secret_file",
                value: "redacted",
                reason: "secret file must contain finite UTF-8 data"
            )
        }
        return configuration.applyingBearerSecret(secret)
    }
}

private struct ServiceCoordinator: Sendable {
    private let configuration: ServiceConfiguration
    private let engine: any ServeEngine
    private let serviceFactory: @Sendable (
        HTTPServiceConfiguration,
        any HTTPTranscriptionHandler,
        ReadinessSource
    ) -> any ServeHTTPService

    init(
        configuration: ServiceConfiguration,
        engine: any ServeEngine,
        serviceFactory: @escaping @Sendable (
            HTTPServiceConfiguration,
            any HTTPTranscriptionHandler,
            ReadinessSource
        ) -> any ServeHTTPService
    ) {
        self.configuration = configuration
        self.engine = engine
        self.serviceFactory = serviceFactory
    }

    func run() async -> CommandResult {
        do {
            try await engine.start()
            guard await engine.isReady else {
                throw TranscriptionDiagnostic(
                    code: .runtimeUnavailable,
                    message: "The runtime is not ready."
                )
            }

            let service = serviceFactory(
                HTTPServiceConfiguration(service: configuration),
                engine,
                ReadinessSource { [engine] in await engine.isReady }
            )

            do {
                try await service.run()
            } catch {
                return await finish(
                    service: service,
                    serverError: error
                )
            }

            return await finish(service: service, serverError: nil)
        } catch {
            let drainResult = await drainEngineInOwnedTask()
            if drainResult != .completed {
                return failure(code: "shutdown_timeout")
            }
            return failure(code: stableFailureCode(for: error))
        }
    }

    private func finish(
        service: any ServeHTTPService,
        serverError: Error?
    ) async -> CommandResult {
        let cleanup = await cleanupInOwnedTask(service: service)
        guard cleanup.httpDrained else {
            return failure(code: "shutdown_timeout")
        }

        guard cleanup.engineDrain == .completed else {
            return failure(code: "shutdown_timeout")
        }

        if let serverError {
            return failure(code: stableFailureCode(for: serverError))
        }
        return CommandResult(exitCode: 0)
    }

    private struct CleanupResult: Sendable {
        let httpDrained: Bool
        let engineDrain: DrainResult
    }

    private func cleanupInOwnedTask(service: any ServeHTTPService) async -> CleanupResult {
        // This unstructured task is owned and awaited. It is intentionally
        // independent from caller cancellation so cleanup can finish.
        let cleanupTask = Task { [configuration, engine] in
            await service.beginDrain()
            let httpDrained = await service.waitForHTTPDrain()
            let engineDrain = await engine.drain(
                timeout: .seconds(configuration.shutdownTimeoutSeconds.value)
            )
            return CleanupResult(httpDrained: httpDrained, engineDrain: engineDrain)
        }
        return await cleanupTask.value
    }

    private func drainEngineInOwnedTask() async -> DrainResult {
        // Startup failure can happen after the caller is cancelled. Await the
        // owned drain task before returning the stable command result.
        let drainTask = Task { [configuration, engine] in
            await engine.drain(timeout: .seconds(configuration.shutdownTimeoutSeconds.value))
        }
        return await drainTask.value
    }

    private func failure(code: String) -> CommandResult {
        CommandResult(exitCode: 1, stderr: "serve_failed: \(code)\n")
    }

    private func stableFailureCode(for error: Error) -> String {
        if error is CancellationError {
            return "cancelled"
        }
        if let diagnostic = error as? TranscriptionDiagnostic {
            return diagnostic.code.rawValue
        }
        if let transportError = error as? HTTPTransportError,
           case .shutdownTimeout = transportError {
            return "shutdown_timeout"
        }
        return "server_failed"
    }
}
