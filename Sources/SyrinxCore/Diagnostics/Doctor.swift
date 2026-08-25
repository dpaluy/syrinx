import Foundation
import Darwin

public struct DoctorReport: Codable, Equatable, Sendable {
    public let platform: String
    public let architecture: String
    public let dataPath: String
    public let cachePath: String
    public let logPath: String
    public let host: String
    public let port: Int
    public let maxUploadBytes: Int
    public let maxDurationSeconds: Int
    public let maxJobs: Int
    public let shutdownTimeoutSeconds: Int
    public let portAvailable: Bool
    public let portMessage: String
    public let writablePaths: [WritablePathStatus]
    public let modelStatus: String

    public init(
        configuration: ServiceConfiguration,
        paths: StandardPaths,
        platform: String = "macOS",
        architecture: String = "arm64",
        portAvailable: Bool,
        portMessage: String,
        writablePaths: [WritablePathStatus],
        modelStatus: String = "missing"
    ) {
        self.platform = platform
        self.architecture = architecture
        dataPath = paths.data.path
        cachePath = paths.cache.path
        logPath = paths.logs.path
        host = configuration.host.value
        port = configuration.port.value
        maxUploadBytes = configuration.maxUploadBytes.value
        maxDurationSeconds = configuration.maxDurationSeconds.value
        maxJobs = configuration.maxJobs.value
        shutdownTimeoutSeconds = configuration.shutdownTimeoutSeconds.value
        self.portAvailable = portAvailable
        self.portMessage = portMessage
        self.writablePaths = writablePaths
        self.modelStatus = modelStatus
    }

    enum CodingKeys: String, CodingKey {
        case platform
        case architecture
        case dataPath = "data_path"
        case cachePath = "cache_path"
        case logPath = "log_path"
        case host
        case port
        case maxUploadBytes = "max_upload_bytes"
        case maxDurationSeconds = "max_duration_seconds"
        case maxJobs = "max_jobs"
        case shutdownTimeoutSeconds = "shutdown_timeout_seconds"
        case portAvailable = "port_available"
        case portMessage = "port_message"
        case writablePaths = "writable_paths"
        case modelStatus = "model_status"
    }
}

public struct PortAvailability: Sendable {
    public init() {}

    public func check(host: HostAddress, port: Port) -> (available: Bool, message: String) {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            return (false, "could not create a socket")
        }
        defer { close(socketDescriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port.value).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr(host.value))

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if result == 0 {
            return (true, "available")
        }
        return (false, String(cString: strerror(errno)))
    }
}

public struct Doctor {
    public let fileManager: FileManager
    public let portAvailability: PortAvailability

    public init(fileManager: FileManager = .default, portAvailability: PortAvailability = .init()) {
        self.fileManager = fileManager
        self.portAvailability = portAvailability
    }

    public func run(configuration: ServiceConfiguration, paths: StandardPaths) -> DoctorReport {
        let port = portAvailability.check(host: configuration.host, port: configuration.port)
        return DoctorReport(
            configuration: configuration,
            paths: paths,
            portAvailable: port.available,
            portMessage: port.message,
            writablePaths: paths.writableStatuses(fileManager: fileManager)
        )
    }
}
