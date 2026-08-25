import Darwin
import Foundation

struct ServiceCommandDependencies: @unchecked Sendable {
    let processRunner: any ServiceProcessRunner
    let preflight: ServicePreflightDependencies
    let healthProbe: any ServiceHealthProbe
    let fileSystem: ServiceFileSystem
    let portOwner: @Sendable (Int, pid_t?) async -> String?
    let uid: uid_t

    init(
        processRunner: any ServiceProcessRunner,
        preflight: ServicePreflightDependencies,
        healthProbe: any ServiceHealthProbe,
        fileSystem: ServiceFileSystem = .init(),
        portOwner: @escaping @Sendable (Int, pid_t?) async -> String? = { _, _ in nil },
        uid: uid_t = getuid()
    ) {
        self.processRunner = processRunner
        self.preflight = preflight
        self.healthProbe = healthProbe
        self.fileSystem = fileSystem
        self.portOwner = portOwner
        self.uid = uid
    }
}

public struct ServiceCommands: Sendable {
    public static let usage = "usage: syrinx service <install|start|stop|restart|status|logs|uninstall|purge> [--json]\n"

    private let environment: [String: String]
    private let paths: StandardPaths
    private let servicePaths: ServicePaths
    private let dependencies: ServiceCommandDependencies
    private let authorityHome: URL?

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        paths: StandardPaths = .init(),
        executableURL: URL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments.first ?? "")
    ) {
        let processRunner = SystemServiceProcessRunner()
        let version = BuildInfo.from(environment: environment).projectVersion
        let trustedHome = try? StandardPaths.trustedCurrentUserHome()
        let productionPaths = trustedHome.map { StandardPaths(homeDirectory: $0.path) }
            ?? StandardPaths(homeDirectory: "/__syrinx_unavailable_authority__")
        self.environment = environment
        self.paths = productionPaths
        authorityHome = trustedHome
        servicePaths = ServicePaths(
            paths: productionPaths,
            homeDirectory: trustedHome?.path ?? "/__syrinx_unavailable_authority__",
            executableURL: executableURL,
            version: version
        )
        dependencies = ServiceCommandDependencies(
            processRunner: processRunner,
            preflight: .production(processRunner: processRunner, environment: environment),
            healthProbe: URLServiceHealthProbe(),
            portOwner: { port, processID in
                await verifiedPortOwner(
                    processRunner: processRunner,
                    port: port,
                    processID: processID
                )
            }
        )
    }

    init(
        environment: [String: String],
        paths: StandardPaths,
        executableURL: URL,
        canonicalAuthorityHome: String,
        dependencies: ServiceCommandDependencies
    ) {
        let version = BuildInfo.from(environment: environment).projectVersion
        self.environment = environment
        self.paths = paths
        authorityHome = URL(fileURLWithPath: canonicalAuthorityHome, isDirectory: true).standardizedFileURL
        servicePaths = ServicePaths(
            paths: paths,
            homeDirectory: canonicalAuthorityHome,
            executableURL: executableURL,
            version: version
        )
        self.dependencies = dependencies
    }

    static func parse(arguments: [String]) throws -> ParsedServiceCommand {
        guard let rawAction = arguments.first,
              let action = ServiceAction(rawValue: rawAction)
        else { throw ServiceCommandUsage() }

        var json = false
        var confirmation: String?
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--json":
                guard !json else { throw ServiceCommandUsage() }
                json = true
                index += 1
            case "--confirm":
                guard action == .purge, confirmation == nil, index + 1 < arguments.count else {
                    throw ServiceCommandUsage()
                }
                confirmation = arguments[index + 1]
                index += 2
            default:
                throw ServiceCommandUsage()
            }
        }
        if action == .purge, confirmation != ServiceIdentity.purgeConfirmationToken {
            throw ServiceCommandUsage()
        }
        if action != .purge, confirmation != nil {
            throw ServiceCommandUsage()
        }
        return ParsedServiceCommand(action: action, json: json, confirmation: confirmation)
    }

    public func run(arguments: [String]) async -> CommandResult {
        let command: ParsedServiceCommand
        do {
            command = try Self.parse(arguments: arguments)
        } catch {
            if arguments.first == ServiceAction.purge.rawValue, arguments.contains("--json") {
                return failure(
                    action: .purge,
                    json: true,
                    error: ServiceFailure(
                        .purgeConfirmationRequired,
                        "purge requires the exact confirmation token"
                    )
                )
            }
            return CommandResult(exitCode: 2, stderr: Self.usage)
        }

        guard authorityHome != nil else {
            return failure(
                action: command.action,
                json: command.json,
                error: ServiceFailure(.unsafePath, "the current user's service authority is unavailable")
            )
        }

        do {
            switch command.action {
            case .install:
                return try await withLifecycleLock { try await self.install(json: command.json, lock: $0) }
            case .start:
                return try await withLifecycleLock { try await self.start(json: command.json, lock: $0) }
            case .stop:
                return try await withLifecycleLock { try await self.stop(json: command.json, lock: $0) }
            case .restart:
                return try await withLifecycleLock { try await self.restart(json: command.json, lock: $0) }
            case .status:
                return try await status(json: command.json)
            case .logs:
                return try await logs(json: command.json)
            case .uninstall:
                return try await withLifecycleLock { try await self.uninstall(json: command.json, lock: $0) }
            case .purge:
                return try await withLifecycleLock { try await self.purge(json: command.json, lock: $0) }
            }
        } catch is CancellationError {
            return failure(
                action: command.action,
                json: command.json,
                error: ServiceFailure(.cancelled, "service command was cancelled")
            )
        } catch {
            return failure(action: command.action, json: command.json, error: map(error))
        }
    }

    private func install(json: Bool, lock: ServiceLifecycleLockHandle) async throws -> CommandResult {
        let manager = launchAgentManager()
        let alreadyInstalled = try await lock.transition {
            try manager.validateInstalledPlistIfPresent()
        }
        let priorStatus = try await lock.transition { try await manager.status() }
        if !alreadyInstalled, priorStatus.status != .notInstalled {
            throw ServiceFailure(
                .launchctlFailed,
                "a loaded service has no trusted plist",
                repairCommand: "syrinx service uninstall"
            )
        }
        if alreadyInstalled, priorStatus.status == .unknown {
            throw ServiceFailure(
                .launchctlFailed,
                "the existing service state is unknown",
                repairCommand: "syrinx service status"
            )
        }
        let retainedConfigurationData = try await lock.transition {
            try persistentConfigurationData()
        }
        let retainedConfiguration: ServiceConfiguration?
        do {
            retainedConfiguration = try retainedConfigurationData.map {
                try JSONDecoder().decode(ServiceConfigurationSnapshot.self, from: $0).makeConfiguration()
            }
        } catch {
            throw ServiceFailure(.configurationError, "retained configuration is invalid")
        }
        let priorPlist = alreadyInstalled
            ? try await lock.transition {
                try dependencies.fileSystem.readExactPrivateFile(servicePaths.plist, limit: 256 * 1024)
            }
            : nil
        let priorConfiguration = retainedConfiguration ?? (try? ServiceConfiguration.load(environment: environment))
        let transaction = try await lock.transition {
            try ServiceInstallTransaction(
                fileSystem: dependencies.fileSystem,
                files: [
                    servicePaths.plist,
                    servicePaths.persistentConfiguration,
                    servicePaths.configuration,
                    servicePaths.stdoutLog,
                    servicePaths.stderrLog
                ],
                trees: [
                    servicePaths.serviceRoot,
                    servicePaths.versionDirectory,
                    paths.cache,
                    paths.logs
                ],
                logFiles: [servicePaths.stdoutLog, servicePaths.stderrLog]
            )
        }
        var managerTouched = false
        do {
            if priorStatus.status != .notInstalled {
                managerTouched = true
                try await lock.transition { try await manager.stop() }
            }
            let preflight = try await lock.transition {
                try await runPreflight(
                    allowOccupiedPort: false,
                    configurationOverride: retainedConfiguration
                )
            }
            try await lock.transition {
                try materializeConfiguration(
                    preflight.configuration,
                    retainedData: retainedConfigurationData
                )
                try dependencies.fileSystem.ensurePrivateFile(servicePaths.stdoutLog)
                try dependencies.fileSystem.ensurePrivateFile(servicePaths.stderrLog)
            }
            managerTouched = true
            try await lock.transition {
                let configurationData = try dependencies.fileSystem.readExactPrivateData(
                    servicePaths.configuration,
                    limit: 512 * 1024
                )
                try await manager.install(plist: ServicePlistBuilder.make(
                    configuration: preflight.configuration,
                    paths: servicePaths,
                    configurationDigest: ServiceConfigurationDigest.forData(configurationData)
                ))
            }
            let result = try await readyResult(
                action: .install,
                configuration: preflight.configuration,
                json: json,
                lock: lock
            )
            return result
        } catch {
            let wasManagerTouched = managerTouched
            do {
                try await uncancelledRecovery {
                    if wasManagerTouched {
                        try await lock.recoveryTransition {
                            try await manager.waitForStableAbsence(
                                timeout: ServiceRecoveryContext.timeout(default: .seconds(10))
                            )
                        }
                    }
                    try await lock.recoveryTransition { try transaction.rollback() }
                    if priorStatus.status != .notInstalled {
                        guard let priorPlist else {
                            throw ServiceFailure(.launchctlFailed, "the prior service restoration was not verified")
                        }
                        try await lock.recoveryTransition {
                            try await manager.restore(plist: priorPlist, priorStatus: priorStatus)
                        }
                        try await verifyRestoredService(
                            manager: manager,
                            priorStatus: priorStatus,
                            configuration: priorConfiguration,
                            lock: lock
                        )
                    } else {
                        let restored = try await lock.recoveryTransition { try await manager.status() }
                        guard restored.status == .notInstalled else {
                            throw ServiceFailure(.launchctlFailed, "the prior service restoration was not verified")
                        }
                    }
                }
            } catch {
                throw ServiceFailure(.launchctlFailed, "the prior service restoration was not verified")
            }
            throw error
        }
    }

    private func start(json: Bool, lock: ServiceLifecycleLockHandle) async throws -> CommandResult {
        let manager = launchAgentManager()
        let current = try await lock.transition { try await manager.status() }
        guard current.status != .notInstalled else {
            throw ServiceFailure(.unsafePath, "the service is not installed")
        }
        guard current.status == .ready || current.status == .starting || current.status == .stopped else {
            throw ServiceFailure(
                .launchctlFailed,
                "the managed service definition is not trusted",
                repairCommand: "syrinx service status"
            )
        }
        let configuration = try await lock.transition {
            try persistedConfiguration() ?? ServiceConfiguration.load(environment: environment)
        }
        if current.status == .ready || current.status == .starting {
            return try await readyResult(
                action: .start,
                configuration: configuration,
                json: json,
                lock: lock
            )
        }
        let preflight = try await lock.transition {
            try await runPreflight(
                allowOccupiedPort: false,
                configurationOverride: configuration
            )
        }
        var startAttempted = false
        do {
            startAttempted = true
            try await lock.transition { try await manager.start() }
            return try await readyResult(
                action: .start,
                configuration: preflight.configuration,
                json: json,
                lock: lock
            )
        } catch {
            if startAttempted {
                do {
                    try await uncancelledRecovery {
                        if current.isLoaded {
                            try await lock.recoveryTransition { try await manager.stopKeepingLoaded() }
                        } else {
                            try await lock.recoveryTransition {
                                try await manager.waitForStableAbsence(
                                    timeout: ServiceRecoveryContext.timeout(default: .seconds(10))
                                )
                            }
                        }
                        let restored = try await lock.recoveryTransition { try await manager.status() }
                        guard restored.status == .stopped,
                              restored.isLoaded == current.isLoaded
                        else {
                            throw ServiceFailure(.launchctlFailed, "the prior service restoration was not verified")
                        }
                    }
                } catch {
                    throw ServiceFailure(.launchctlFailed, "the prior service restoration was not verified")
                }
            }
            throw error
        }
    }

    private func restart(json: Bool, lock: ServiceLifecycleLockHandle) async throws -> CommandResult {
        let manager = launchAgentManager()
        let current = try await lock.transition { try await manager.status() }
        guard current.status != .notInstalled else {
            throw ServiceFailure(.unsafePath, "the service is not installed")
        }
        guard current.status == .ready || current.status == .starting || current.status == .stopped else {
            throw ServiceFailure(
                .launchctlFailed,
                "the managed service definition is not trusted",
                repairCommand: "syrinx service status"
            )
        }
        let configuration = try await lock.transition {
            try persistedConfiguration() ?? ServiceConfiguration.load(environment: environment)
        }
        let allowOccupied = current.status == .ready || current.status == .starting
        if allowOccupied,
           await dependencies.portOwner(configuration.port.value, current.processID) == nil {
            throw ServiceFailure(.portOccupied, "the configured port is not owned by the service")
        }
        let preflight = try await lock.transition {
            try await runPreflight(
                allowOccupiedPort: allowOccupied,
                configurationOverride: configuration
            )
        }
        let priorPlist = try await lock.recoveryTransition {
            try dependencies.fileSystem.readExactPrivateFile(servicePaths.plist, limit: 256 * 1024)
        }
        var stopAttempted = false
        do {
            stopAttempted = true
            try await lock.transition { try await manager.stop() }
            try await lock.transition { try await manager.start() }
            return try await readyResult(
                action: .restart,
                configuration: preflight.configuration,
                json: json,
                lock: lock
            )
        } catch {
            if stopAttempted {
                do {
                    try await uncancelledRecovery {
                        try await lock.recoveryTransition {
                            try await manager.waitForStableAbsence(
                                timeout: ServiceRecoveryContext.timeout(default: .seconds(10))
                            )
                        }
                        try await lock.recoveryTransition {
                            try await manager.restore(plist: priorPlist, priorStatus: current)
                        }
                        try await verifyRestoredService(
                            manager: manager,
                            priorStatus: current,
                            configuration: configuration,
                            lock: lock
                        )
                    }
                } catch {
                    throw ServiceFailure(.launchctlFailed, "the prior service restoration was not verified")
                }
            }
            throw error
        }
    }

    private func verifyRestoredService(
        manager: LaunchAgentManager,
        priorStatus: LaunchAgentStatus,
        configuration: ServiceConfiguration?,
        lock: ServiceLifecycleLockHandle
    ) async throws {
        let shouldBeRunning = priorStatus.status == .ready || priorStatus.status == .starting
        let restored: LaunchAgentStatus
        if shouldBeRunning {
            restored = try await lock.recoveryTransition {
                try await manager.waitForReady(
                    timeout: ServiceRecoveryContext.timeout(default: .seconds(10))
                )
            }
        } else {
            restored = try await lock.recoveryTransition { try await manager.status() }
        }
        if !shouldBeRunning {
            guard restored.status == .stopped,
                  restored.isLoaded == priorStatus.isLoaded
            else {
                throw ServiceFailure(.launchctlFailed, "the prior service restoration was not verified")
            }
            return
        }

        guard restored.status == .ready,
              restored.processID != nil,
              let configuration
        else {
            throw ServiceFailure(.launchctlFailed, "the prior service restoration was not verified")
        }
        let authorization = try configuredBearerSecret(
            configuration,
            fileSystem: dependencies.fileSystem
        )
        try ServiceRecoveryContext.consume()
        let health = await dependencies.healthProbe.waitUntilReady(
            port: configuration.port.value,
            authorization: authorization,
            timeout: ServiceRecoveryContext.timeout(default: .seconds(10))
        )
        try ServiceRecoveryContext.consume()
        guard health.state == .ready,
              await dependencies.portOwner(configuration.port.value, restored.processID) != nil
        else {
            throw ServiceFailure(.launchctlFailed, "the prior service restoration was not verified")
        }
    }

    private func stop(json: Bool, lock: ServiceLifecycleLockHandle) async throws -> CommandResult {
        let manager = launchAgentManager()
        let trusted = try await lock.transition { try manager.validateInstalledDefinitionIfPresent() }
        if !trusted {
            let current = try await lock.transition { try await manager.status() }
            guard current.status == .notInstalled else {
                throw ServiceFailure(.unsafePath, "the managed service definition is missing or untrusted")
            }
        } else {
            try await lock.transition { try await manager.stop() }
        }
        return render(
            ServiceStatusReport(
                action: ServiceAction.stop.rawValue,
                status: .stopped,
                message: "service stopped"
            ),
            exitCode: 0,
            json: json
        )
    }

    private func status(json: Bool) async throws -> CommandResult {
        let manager = launchAgentManager()
        let current = try await manager.status()
        if current.status == .notInstalled {
            return render(
                ServiceStatusReport(
                    action: ServiceAction.status.rawValue,
                    status: .notInstalled,
                    message: "service is not installed"
                ),
                exitCode: 0,
                json: json
            )
        }
        if current.status == .unknown {
            return render(
                ServiceStatusReport(
                    action: ServiceAction.status.rawValue,
                    status: .unknown,
                    message: "service state is unknown",
                    launchctlState: current.state
                ),
                exitCode: 1,
                json: json
            )
        }
        if current.status == .stopped || current.status == .starting {
            return render(
                ServiceStatusReport(
                    action: ServiceAction.status.rawValue,
                    status: current.status,
                    message: "service is \(current.status.rawValue.replacingOccurrences(of: "_", with: " "))",
                    launchctlState: current.state
                ),
                exitCode: 0,
                json: json
            )
        }

        let configuration = try persistedConfiguration() ?? ServiceConfiguration.load(environment: environment)
        let authorization = try configuredBearerSecret(
            configuration,
            fileSystem: dependencies.fileSystem
        )
        let health = await dependencies.healthProbe.waitUntilReady(
            port: configuration.port.value,
            authorization: authorization,
            timeout: .seconds(1)
        )
        let owner = health.state == .ready
            ? await dependencies.portOwner(configuration.port.value, current.processID)
            : nil
        let status: ServiceStatusKind = health.state == .ready && owner != nil ? .ready : .unhealthy
        return render(
            ServiceStatusReport(
                action: ServiceAction.status.rawValue,
                status: status,
                message: status == .ready ? "service is ready" : "service health check failed",
                launchctlState: current.state,
                portOwner: owner
            ),
            exitCode: status == .ready ? 0 : 1,
            json: json
        )
    }

    private func logs(json: Bool) async throws -> CommandResult {
        let manager = launchAgentManager()
        guard try dependencies.fileSystem.exists(servicePaths.plist) else {
            throw ServiceFailure(.logsUnavailable, "service is not installed")
        }
        let value = try manager.readLogs()
        let report = ServiceStatusReport(
            action: ServiceAction.logs.rawValue,
            status: .stopped,
            message: value.isEmpty ? "no service logs" : "bounded service logs",
            logs: value
        )
        return render(report, exitCode: 0, json: json, preferLogs: !json)
    }

    private func uninstall(json: Bool, lock: ServiceLifecycleLockHandle) async throws -> CommandResult {
        let manager = launchAgentManager()
        let hadPlist = try await lock.transition { try manager.validateInstalledDefinitionIfPresent() }
        if !hadPlist {
            let current = try await lock.transition { try await manager.status() }
            guard current.status == .notInstalled else {
                throw ServiceFailure(.unsafePath, "the managed service definition is missing or untrusted")
            }
        } else {
            try await lock.transition { try await manager.stop() }
        }
        if hadPlist { try await lock.transition { try manager.removePlist() } }
        var deleted: [String] = hadPlist ? ["launch_agent"] : []
        for (name, url) in [
            ("service_state", servicePaths.serviceRoot),
            ("cache", paths.cache),
            ("logs", paths.logs)
        ] {
            if try await lock.transition({ try dependencies.fileSystem.exists(url) }) {
                try await lock.transition { try dependencies.fileSystem.removeTreeIfPresent(url) }
                deleted.append(name)
            }
        }
        return render(
            ServiceStatusReport(
                action: ServiceAction.uninstall.rawValue,
                status: .notInstalled,
                message: "service uninstalled; models and user configuration retained",
                deleted: deleted
            ),
            exitCode: 0,
            json: json
        )
    }

    private func purge(json: Bool, lock: ServiceLifecycleLockHandle) async throws -> CommandResult {
        let targets: [(String, URL)] = [
            ("launch_agent", servicePaths.plist),
            ("cache", paths.cache),
            ("logs", paths.logs),
            ("all_product_data", paths.data)
        ]
        try await lock.transition { try validatePurgeTargets(targets.map(\.1)) }
        let manager = launchAgentManager()
        let trusted = try await lock.transition { try manager.validateInstalledDefinitionIfPresent() }
        if trusted {
            try await lock.transition { try await manager.stop() }
        } else {
            let current = try await lock.transition { try await manager.status() }
            guard current.status == .notInstalled else {
                throw ServiceFailure(.unsafePath, "the managed service definition is missing or untrusted")
            }
        }

        var deleted: [String] = []
        for target in targets {
            let (name, url) = target
            if try await lock.transition({ try dependencies.fileSystem.exists(url) }) {
                try await lock.transition { try dependencies.fileSystem.removeTreeIfPresent(url) }
                deleted.append(name)
            }
        }
        return render(
            ServiceStatusReport(
                action: ServiceAction.purge.rawValue,
                status: .notInstalled,
                message: "purge completed; listed targets were deleted",
                deleted: deleted
            ),
            exitCode: 0,
            json: json
        )
    }

    private func runPreflight(allowOccupiedPort: Bool) async throws -> ServicePreflightReport {
        try await runPreflight(allowOccupiedPort: allowOccupiedPort, configurationOverride: nil)
    }

    private func runPreflight(
        allowOccupiedPort: Bool,
        configurationOverride: ServiceConfiguration?
    ) async throws -> ServicePreflightReport {
        try await ServicePreflight(
            environment: environment,
            paths: paths,
            servicePaths: servicePaths,
            configurationOverride: configurationOverride,
            dependencies: dependencies.preflight,
            fileSystem: dependencies.fileSystem
        ).run(allowOccupiedPort: allowOccupiedPort)
    }

    private func writeConfiguration(_ configuration: ServiceConfiguration) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ServiceConfigurationSnapshot(configuration: configuration))
        try dependencies.fileSystem.writePrivateFileAtomically(data, to: servicePaths.persistentConfiguration)
        try dependencies.fileSystem.writePrivateFileAtomically(data, to: servicePaths.configuration)
    }

    private func materializeConfiguration(
        _ configuration: ServiceConfiguration,
        retainedData: Data?
    ) throws {
        if let retainedData {
            try dependencies.fileSystem.writePrivateFileAtomically(
                retainedData,
                to: servicePaths.configuration
            )
        } else {
            try writeConfiguration(configuration)
        }
    }

    private func persistedConfiguration() throws -> ServiceConfiguration? {
        guard let data = try persistentConfigurationData() else { return nil }
        return try JSONDecoder().decode(ServiceConfigurationSnapshot.self, from: data).makeConfiguration()
    }

    private func persistentConfigurationData() throws -> Data? {
        guard try dependencies.fileSystem.exists(servicePaths.persistentConfiguration) else { return nil }
        return try dependencies.fileSystem.readExactPrivateData(
            servicePaths.persistentConfiguration,
            limit: 512 * 1024
        )
    }

    private func withLifecycleLock(
        _ operation: @escaping @Sendable (ServiceLifecycleLockHandle) async throws -> CommandResult
    ) async throws -> CommandResult {
        try await ServiceLifecycleLock(
            path: servicePaths.lifecycleLock,
            fileSystem: dependencies.fileSystem
        ).withLock(operation)
    }

    private func uncancelledRecovery(
        _ operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        let budget = ServiceRecoveryBudget()
        let recovery = Task.detached(priority: .userInitiated) {
            try await ServiceRecoveryContext.$budget.withValue(budget) {
                try await operation()
            }
        }
        try await recovery.value
    }

    private func readyResult(
        action: ServiceAction,
        configuration: ServiceConfiguration,
        json: Bool,
        lock: ServiceLifecycleLockHandle
    ) async throws -> CommandResult {
        let authorization = try configuredBearerSecret(
            configuration,
            fileSystem: dependencies.fileSystem
        )
        let health = await dependencies.healthProbe.waitUntilReady(
            port: configuration.port.value,
            authorization: authorization,
            timeout: .seconds(10)
        )
        if Task.isCancelled {
            throw CancellationError()
        }
        guard health.state == .ready else {
            let manager = launchAgentManager()
            let state = try? await lock.transition { try await manager.status() }
            let logs = try? await lock.transition { try manager.readLogs() }
            throw ServiceFailure(
                .healthTimeout,
                "service did not become healthy",
                repairCommand: "syrinx service status",
                launchctlState: state?.state,
                logs: logs,
                portOwner: await dependencies.portOwner(configuration.port.value, state?.processID)
            )
        }
        let manager = launchAgentManager()
        let state: LaunchAgentStatus
        do {
            state = try await lock.transition {
                try await manager.waitForReady(timeout: .seconds(10))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let observed = try? await lock.transition { try await manager.status() }
            let logs = try? await lock.transition { try manager.readLogs() }
            throw ServiceFailure(
                .healthTimeout,
                "service did not become ready",
                repairCommand: "syrinx service status",
                launchctlState: observed?.state,
                logs: logs,
                portOwner: await dependencies.portOwner(configuration.port.value, observed?.processID)
            )
        }
        let owner = await dependencies.portOwner(configuration.port.value, state.processID)
        guard state.status == .ready, owner != nil else {
            throw ServiceFailure(
                .healthTimeout,
                "service health responded without verified process ownership",
                repairCommand: "syrinx service status",
                launchctlState: state.state,
                portOwner: owner
            )
        }
        return render(
            ServiceStatusReport(
                action: action.rawValue,
                status: .ready,
                message: "service is ready"
            ),
            exitCode: 0,
            json: json
        )
    }

    private func validatePurgeTargets(_ urls: [URL]) throws {
        let home = servicePaths.homeDirectory.standardizedFileURL.path
        for url in urls {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(home + "/Library/"), path != home else {
                throw ServiceFailure(.unsafePath, "purge target is ambiguous or unsafe")
            }
            try dependencies.fileSystem.validateTreeIfPresent(url)
        }
    }

    private func launchAgentManager() -> LaunchAgentManager {
        LaunchAgentManager(
            paths: servicePaths,
            processRunner: dependencies.processRunner,
            fileSystem: dependencies.fileSystem,
            uid: dependencies.uid
        )
    }

    private func render(
        _ report: ServiceStatusReport,
        exitCode: Int,
        json: Bool,
        preferLogs: Bool = false
    ) -> CommandResult {
        if json {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                return CommandResult(
                    exitCode: exitCode,
                    stdout: String(decoding: try encoder.encode(report), as: UTF8.self) + "\n"
                )
            } catch {
                return CommandResult(exitCode: 1, stderr: "service command failed\n")
            }
        }
        if preferLogs, let logs = report.logs, !logs.isEmpty {
            return CommandResult(
                exitCode: exitCode,
                stdout: logs + (logs.hasSuffix("\n") ? "" : "\n")
            )
        }
        var lines = [
            "service: \(report.identity)",
            "action: \(report.action)",
            "status: \(report.status.rawValue)",
            "message: \(report.message)"
        ]
        if let repair = report.repairCommand { lines.append("repair: \(repair)") }
        if let state = report.launchctlState { lines.append("launchctl: \(state)") }
        if let owner = report.portOwner { lines.append("port owner: \(owner)") }
        if !report.deleted.isEmpty {
            lines.append("deleted: \(report.deleted.joined(separator: ", "))")
        }
        return CommandResult(exitCode: exitCode, stdout: lines.joined(separator: "\n") + "\n")
    }

    private func failure(
        action: ServiceAction,
        json: Bool,
        error: ServiceFailure
    ) -> CommandResult {
        let report = ServiceStatusReport(
            action: action.rawValue,
            status: error.code == .healthTimeout ? .unhealthy : .unknown,
            errorCode: error.code.rawValue,
            message: error.message,
            repairCommand: error.repairCommand,
            launchctlState: error.launchctlState,
            portOwner: error.portOwner,
            logs: error.logs
        )
        let result = render(
            report,
            exitCode: error.code == .purgeConfirmationRequired ? 2 : 1,
            json: json
        )
        if json { return result }
        return CommandResult(
            exitCode: result.exitCode,
            stderr: "service_failed: \(error.code.rawValue)\n\(result.stdout)"
        )
    }

    private func map(_ error: Error) -> ServiceFailure {
        if let error = error as? ServiceFailure { return error }
        if error is CancellationError {
            return ServiceFailure(.cancelled, "service command was cancelled")
        }
        if let error = error as? LaunchAgentError {
            if error.operation == "plist" {
                return ServiceFailure(.unsafePath, "service plist validation failed")
            }
            return ServiceFailure(.launchctlFailed, "launchctl operation failed")
        }
        if let error = error as? ServiceProcessError {
            if error == .cancelled {
                return ServiceFailure(.cancelled, "service command was cancelled")
            }
            return ServiceFailure(.launchctlFailed, "launchctl operation failed")
        }
        if error is ServiceFileSystemError {
            return ServiceFailure(.unsafePath, "service path validation failed")
        }
        if error is ServiceLifecycleLockError {
            return ServiceFailure(.lifecycleBusy, "another service lifecycle command is active")
        }
        if error is ConfigurationError {
            return ServiceFailure(.configurationError, "configuration is invalid")
        }
        return ServiceFailure(.launchctlFailed, "service command failed")
    }
}

func verifiedPortOwner(
    processRunner: any ServiceProcessRunner,
    port: Int,
    processID: pid_t?
) async -> String? {
    guard let processID, processID > 0 else { return nil }
    do {
        try ServiceRecoveryContext.consume()
    } catch {
        return nil
    }
    let result = try? await processRunner.run(
        executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
        arguments: [
            "-nP", "-a", "-p", String(processID),
            "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpn"
        ],
        environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"],
        timeout: ServiceRecoveryContext.timeout(default: .seconds(2))
    )
    do {
        try ServiceRecoveryContext.consume()
    } catch {
        return nil
    }
    guard let result, result.exitCode == 0 else { return nil }
    var currentPID: pid_t?
    for line in result.stdout.split(whereSeparator: \.isNewline).map(String.init) {
        guard let field = line.first else { return nil }
        let value = String(line.dropFirst())
        switch field {
        case "p":
            guard let value = Int32(value), value > 0 else { return nil }
            currentPID = value
        case "n":
            guard currentPID == processID else { continue }
            if networkFieldContainsExactPort(value, port: port) {
                return "pid:\(processID)"
            }
        case "f":
            continue
        default:
            return nil
        }
    }
    return nil
}

private func networkFieldContainsExactPort(_ value: String, port: Int) -> Bool {
    value == "127.0.0.1:\(port)"
}

private struct ServiceCommandUsage: Error {}
