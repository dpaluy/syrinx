import CryptoKit
import Foundation

/// Stable public identity for the native Parakeet service.
public enum ServiceIdentity {
    public static let developmentOnly = false
    public static let label = "com.dpaluy.syrinx"
    public static let displayName = "Syrinx"
    public static let purgeConfirmationToken = "PURGE-SYRINX"
    public static let executableName = "syrinx"
    public static let configurationFileName = "configuration.json"
}

public enum ServiceAction: String, CaseIterable, Codable, Sendable {
    case install
    case start
    case stop
    case restart
    case status
    case logs
    case uninstall
    case purge
}

struct ParsedServiceCommand: Equatable, Sendable {
    let action: ServiceAction
    let json: Bool
    let confirmation: String?
}

public enum ServiceStatusKind: String, Codable, Sendable {
    case notInstalled = "not_installed"
    case stopped
    case starting
    case ready
    case unhealthy
    case unknown
}

public struct ServiceStatusReport: Codable, Equatable, Sendable {
    public let action: String
    public let identity: String
    public let placeholderIdentity: Bool
    public let status: ServiceStatusKind
    public let errorCode: String?
    public let message: String
    public let repairCommand: String?
    public let launchctlState: String?
    public let portOwner: String?
    public let logs: String?
    public let deleted: [String]

    public init(
        action: String,
        identity: String = ServiceIdentity.label,
        placeholderIdentity: Bool = ServiceIdentity.developmentOnly,
        status: ServiceStatusKind,
        errorCode: String? = nil,
        message: String,
        repairCommand: String? = nil,
        launchctlState: String? = nil,
        portOwner: String? = nil,
        logs: String? = nil,
        deleted: [String] = []
    ) {
        self.action = action
        self.identity = identity
        self.placeholderIdentity = placeholderIdentity
        self.status = status
        self.errorCode = errorCode
        self.message = message
        self.repairCommand = repairCommand
        self.launchctlState = launchctlState
        self.portOwner = portOwner
        self.logs = logs
        self.deleted = deleted
    }

    enum CodingKeys: String, CodingKey {
        case action
        case identity
        case placeholderIdentity = "placeholder_identity"
        case status
        case errorCode = "error_code"
        case message
        case repairCommand = "repair_command"
        case launchctlState = "launchctl_state"
        case portOwner = "port_owner"
        case logs
        case deleted
    }
}

public struct ServicePaths: Equatable, Sendable {
    public let homeDirectory: URL
    public let launchAgentsDirectory: URL
    public let plist: URL
    public let serviceRoot: URL
    public let selection: URL
    public let versionDirectory: URL
    public let candidateMetadata: URL
    public let persistentConfiguration: URL
    public let configuration: URL
    public let lifecycleLock: URL
    public let stdoutLog: URL
    public let stderrLog: URL
    public let executable: URL
    public let version: String

    public init(
        paths: StandardPaths,
        homeDirectory: String,
        executableURL: URL,
        version: String
    ) {
        let home = URL(fileURLWithPath: homeDirectory, isDirectory: true).standardizedFileURL
        let serviceRoot = paths.data
            .appendingPathComponent("service", isDirectory: true)
            .standardizedFileURL
        let versionDirectory = serviceRoot
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
            .standardizedFileURL
        self.homeDirectory = home
        launchAgentsDirectory = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .standardizedFileURL
        plist = launchAgentsDirectory.appendingPathComponent("\(ServiceIdentity.label).plist")
        self.serviceRoot = serviceRoot
        selection = serviceRoot.appendingPathComponent(
            ServiceVersionedLayout.selectionFileName,
            isDirectory: false
        )
        self.versionDirectory = versionDirectory
        candidateMetadata = ServiceVersionedLayout.candidateMetadata(
            versionDirectory: versionDirectory
        )
        persistentConfiguration = paths.data
            .appendingPathComponent(ServiceIdentity.configurationFileName, isDirectory: false)
            .standardizedFileURL
        configuration = versionDirectory.appendingPathComponent(
            ServiceIdentity.configurationFileName,
            isDirectory: false
        )
        lifecycleLock = home
            .appendingPathComponent(".service-lifecycle.lock", isDirectory: false)
            .standardizedFileURL
        stdoutLog = paths.logs
            .appendingPathComponent("service.stdout.log", isDirectory: false)
            .standardizedFileURL
        stderrLog = paths.logs
            .appendingPathComponent("service.stderr.log", isDirectory: false)
            .standardizedFileURL
        executable = executableURL.standardizedFileURL
        self.version = version
    }
}

enum ServiceFailureCode: String, Sendable {
    case configurationError = "configuration_error"
    case modelUnavailable = "model_unavailable"
    case unsafePath = "unsafe_path"
    case insufficientDisk = "insufficient_disk"
    case portOccupied = "port_occupied"
    case invalidSecretSource = "invalid_secret_source"
    case signatureInvalid = "signature_invalid"
    case foregroundStartFailed = "foreground_start_failed"
    case launchctlFailed = "launchctl_failed"
    case healthTimeout = "health_timeout"
    case logsUnavailable = "logs_unavailable"
    case lifecycleBusy = "lifecycle_busy"
    case cancelled = "cancelled"
    case purgeConfirmationRequired = "purge_confirmation_required"
}

struct ServiceFailure: Error, Equatable, Sendable {
    let code: ServiceFailureCode
    let message: String
    let repairCommand: String?
    let launchctlState: String?
    let logs: String?
    let portOwner: String?

    init(
        _ code: ServiceFailureCode,
        _ message: String,
        repairCommand: String? = nil,
        launchctlState: String? = nil,
        logs: String? = nil,
        portOwner: String? = nil
    ) {
        self.code = code
        self.message = message
        self.repairCommand = repairCommand
        self.launchctlState = launchctlState
        self.logs = logs
        self.portOwner = portOwner
    }
}

enum ServiceConfigurationDigest {
    static func forConfiguration(_ configuration: ServiceConfiguration) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try forData(encoder.encode(ServiceConfigurationSnapshot(configuration: configuration)))
    }

    static func forData(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isValid(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            ("0"..."9").contains($0) || ("a"..."f").contains($0)
        }
    }
}

enum ServiceRecoveryError: Error, Equatable, Sendable {
    case budgetExceeded
}

final class ServiceRecoveryBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let deadline: ContinuousClock.Instant
    private let maximumOperations: Int
    private var operations = 0

    init(timeout: Duration = .seconds(15), maximumOperations: Int = 128) {
        deadline = ContinuousClock.now.advanced(by: timeout)
        self.maximumOperations = maximumOperations
    }

    func consume() throws {
        lock.lock()
        defer { lock.unlock() }
        guard operations < maximumOperations, ContinuousClock.now < deadline else {
            throw ServiceRecoveryError.budgetExceeded
        }
        operations += 1
    }

    func timeout(default value: Duration) -> Duration {
        lock.lock()
        defer { lock.unlock() }
        let remaining = ContinuousClock.now.duration(to: deadline)
        return remaining < value ? max(.zero, remaining) : value
    }
}

enum ServiceRecoveryContext {
    @TaskLocal static var budget: ServiceRecoveryBudget?

    static func consume() throws {
        try budget?.consume()
    }

    static func timeout(default value: Duration) -> Duration {
        budget?.timeout(default: value) ?? value
    }
}
