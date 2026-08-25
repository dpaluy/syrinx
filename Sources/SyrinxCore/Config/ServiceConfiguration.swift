import Foundation

public enum ConfigurationError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidValue(key: String, value: String, reason: String)

    public var description: String {
        switch self {
        case let .invalidValue(key, value, reason):
            return "invalid value for \(key) (\(value)): \(reason)"
        }
    }
}

public struct HostAddress: Equatable, Sendable {
    private let rawValue: String

    public init(_ value: String) throws {
        guard value == "127.0.0.1" else {
            throw ConfigurationError.invalidValue(
                key: "SYRINX_HOST",
                value: value,
                reason: "must be the loopback address 127.0.0.1"
            )
        }
        rawValue = value
    }

    public static let loopback = try! HostAddress("127.0.0.1")

    public var value: String { rawValue }
}

public struct Port: Equatable, Sendable {
    public let value: Int

    public init(_ value: Int, key: String = "SYRINX_PORT") throws {
        guard (1...65_535).contains(value) else {
            throw ConfigurationError.invalidValue(
                key: key,
                value: String(value),
                reason: "must be between 1 and 65535"
            )
        }
        self.value = value
    }
}

public struct ByteLimit: Equatable, Sendable {
    public let value: Int

    public init(_ value: Int, key: String) throws {
        guard value > 0 else {
            throw ConfigurationError.invalidValue(
                key: key,
                value: String(value),
                reason: "must be greater than zero"
            )
        }
        self.value = value
    }
}

public struct DurationLimit: Equatable, Sendable {
    public let value: Int

    public init(_ value: Int, key: String) throws {
        guard value > 0 else {
            throw ConfigurationError.invalidValue(
                key: key,
                value: String(value),
                reason: "must be greater than zero"
            )
        }
        self.value = value
    }
}

public struct JobLimit: Equatable, Sendable {
    public let value: Int

    public init(_ value: Int, key: String) throws {
        guard value > 0 else {
            throw ConfigurationError.invalidValue(
                key: key,
                value: String(value),
                reason: "must be greater than zero"
            )
        }
        self.value = value
    }
}

public struct ShutdownTimeout: Equatable, Sendable {
    public let value: Int

    public init(_ value: Int, key: String) throws {
        guard value > 0 else {
            throw ConfigurationError.invalidValue(
                key: key,
                value: String(value),
                reason: "must be greater than zero"
            )
        }
        self.value = value
    }
}

public struct ModelIdentifier: Equatable, Sendable {
    public let value: String

    public init(_ value: String, key: String = "SYRINX_MODEL_ID") throws {
        guard !value.isEmpty,
              value.count <= 128,
              value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." })
        else {
            throw ConfigurationError.invalidValue(
                key: key,
                value: value,
                reason: "must contain 1 to 128 letters, numbers, dots, hyphens, or underscores"
            )
        }
        self.value = value
    }
}

public struct ServiceConfiguration: Equatable, Sendable {
    public static let defaultModelID = "parakeet-tdt-0.6b-v3"
    public static let defaultMaxUploadBytes = 25 * 1024 * 1024
    public static let defaultMaxEnvelopeBytes = 26 * 1024 * 1024
    public static let defaultMaxDurationSeconds = 3_600
    public static let defaultMaxJobs = 1
    public static let defaultHTTPIdleTimeoutMilliseconds = 30_000
    public static let defaultHTTPRequestTimeoutMilliseconds = 120_000
    public static let defaultHTTPHeaderFieldBytes = 8 * 1024
    public static let defaultHTTPHeaderListBytes = 16 * 1024
    public static let defaultHTTPHeaderFieldCount = 100
    public static let defaultShutdownTimeoutSeconds = 30

    public let host: HostAddress
    public let port: Port
    public let modelID: ModelIdentifier
    public let maxUploadBytes: ByteLimit
    public let maxEnvelopeBytes: ByteLimit
    public let maxDurationSeconds: DurationLimit
    public let maxJobs: JobLimit
    public let httpIdleTimeoutMilliseconds: DurationLimit
    public let httpRequestTimeoutMilliseconds: DurationLimit
    public let httpHeaderFieldBytes: ByteLimit
    public let httpHeaderListBytes: ByteLimit
    public let httpHeaderFieldCount: JobLimit
    public let shutdownTimeoutSeconds: ShutdownTimeout
    public let bearerSecretFile: String?
    public let bearerSecret: String?

    public init(
        host: HostAddress = .loopback,
        port: Port = try! Port(5_092),
        modelID: ModelIdentifier = try! ModelIdentifier(defaultModelID),
        maxUploadBytes: ByteLimit = try! ByteLimit(defaultMaxUploadBytes, key: "SYRINX_MAX_UPLOAD_BYTES"),
        maxEnvelopeBytes: ByteLimit = try! ByteLimit(defaultMaxEnvelopeBytes, key: "SYRINX_MAX_ENVELOPE_BYTES"),
        maxDurationSeconds: DurationLimit = try! DurationLimit(defaultMaxDurationSeconds, key: "SYRINX_MAX_DURATION_SECONDS"),
        maxJobs: JobLimit = try! JobLimit(defaultMaxJobs, key: "SYRINX_MAX_JOBS"),
        httpIdleTimeoutMilliseconds: DurationLimit = try! DurationLimit(defaultHTTPIdleTimeoutMilliseconds, key: "SYRINX_HTTP_IDLE_TIMEOUT_MILLISECONDS"),
        httpRequestTimeoutMilliseconds: DurationLimit = try! DurationLimit(defaultHTTPRequestTimeoutMilliseconds, key: "SYRINX_HTTP_REQUEST_TIMEOUT_MILLISECONDS"),
        httpHeaderFieldBytes: ByteLimit = try! ByteLimit(defaultHTTPHeaderFieldBytes, key: "SYRINX_HTTP_HEADER_FIELD_BYTES"),
        httpHeaderListBytes: ByteLimit = try! ByteLimit(defaultHTTPHeaderListBytes, key: "SYRINX_HTTP_HEADER_LIST_BYTES"),
        httpHeaderFieldCount: JobLimit = try! JobLimit(defaultHTTPHeaderFieldCount, key: "SYRINX_HTTP_HEADER_FIELD_COUNT"),
        shutdownTimeoutSeconds: ShutdownTimeout = try! ShutdownTimeout(defaultShutdownTimeoutSeconds, key: "SYRINX_SHUTDOWN_TIMEOUT_SECONDS"),
        bearerSecretFile: String? = nil,
        bearerSecret: String? = nil
    ) {
        self.host = host
        self.port = port
        self.modelID = modelID
        self.maxUploadBytes = maxUploadBytes
        self.maxEnvelopeBytes = maxEnvelopeBytes
        self.maxDurationSeconds = maxDurationSeconds
        self.maxJobs = maxJobs
        self.httpIdleTimeoutMilliseconds = httpIdleTimeoutMilliseconds
        self.httpRequestTimeoutMilliseconds = httpRequestTimeoutMilliseconds
        self.httpHeaderFieldBytes = httpHeaderFieldBytes
        self.httpHeaderListBytes = httpHeaderListBytes
        self.httpHeaderFieldCount = httpHeaderFieldCount
        self.shutdownTimeoutSeconds = shutdownTimeoutSeconds
        self.bearerSecretFile = bearerSecretFile
        self.bearerSecret = bearerSecret?.isEmpty == false ? bearerSecret : nil
    }

    public static func load(environment: [String: String]) throws -> Self {
        let hostValue = environment["SYRINX_HOST"] ?? HostAddress.loopback.value
        let host = try HostAddress(hostValue)
        let port = try Port(integer(environment, key: "SYRINX_PORT", default: 5_092))
        let modelID = try ModelIdentifier(environment["SYRINX_MODEL_ID"] ?? defaultModelID)
        let maxUploadBytes = try ByteLimit(
            integer(environment, key: "SYRINX_MAX_UPLOAD_BYTES", default: defaultMaxUploadBytes),
            key: "SYRINX_MAX_UPLOAD_BYTES"
        )
        let maxEnvelopeBytes = try ByteLimit(
            integer(environment, key: "SYRINX_MAX_ENVELOPE_BYTES", default: defaultMaxEnvelopeBytes),
            key: "SYRINX_MAX_ENVELOPE_BYTES"
        )
        let maxDurationSeconds = try DurationLimit(
            integer(environment, key: "SYRINX_MAX_DURATION_SECONDS", default: defaultMaxDurationSeconds),
            key: "SYRINX_MAX_DURATION_SECONDS"
        )
        let maxJobs = try JobLimit(
            integer(environment, key: "SYRINX_MAX_JOBS", default: defaultMaxJobs),
            key: "SYRINX_MAX_JOBS"
        )
        let httpIdleTimeoutMilliseconds = try DurationLimit(
            integer(environment, key: "SYRINX_HTTP_IDLE_TIMEOUT_MILLISECONDS", default: defaultHTTPIdleTimeoutMilliseconds),
            key: "SYRINX_HTTP_IDLE_TIMEOUT_MILLISECONDS"
        )
        let httpRequestTimeoutMilliseconds = try DurationLimit(
            integer(environment, key: "SYRINX_HTTP_REQUEST_TIMEOUT_MILLISECONDS", default: defaultHTTPRequestTimeoutMilliseconds),
            key: "SYRINX_HTTP_REQUEST_TIMEOUT_MILLISECONDS"
        )
        let httpHeaderFieldBytes = try ByteLimit(
            integer(environment, key: "SYRINX_HTTP_HEADER_FIELD_BYTES", default: defaultHTTPHeaderFieldBytes),
            key: "SYRINX_HTTP_HEADER_FIELD_BYTES"
        )
        let httpHeaderListBytes = try ByteLimit(
            integer(environment, key: "SYRINX_HTTP_HEADER_LIST_BYTES", default: defaultHTTPHeaderListBytes),
            key: "SYRINX_HTTP_HEADER_LIST_BYTES"
        )
        let httpHeaderFieldCount = try JobLimit(
            integer(environment, key: "SYRINX_HTTP_HEADER_FIELD_COUNT", default: defaultHTTPHeaderFieldCount),
            key: "SYRINX_HTTP_HEADER_FIELD_COUNT"
        )
        let shutdownTimeoutSeconds = try ShutdownTimeout(
            integer(
            environment,
            key: "SYRINX_SHUTDOWN_TIMEOUT_SECONDS",
            default: defaultShutdownTimeoutSeconds
            ),
            key: "SYRINX_SHUTDOWN_TIMEOUT_SECONDS"
        )
        let bearerSecretFile = try secretFileReference(environment: environment)

        return Self(
            host: host,
            port: port,
            modelID: modelID,
            maxUploadBytes: maxUploadBytes,
            maxEnvelopeBytes: maxEnvelopeBytes,
            maxDurationSeconds: maxDurationSeconds,
            maxJobs: maxJobs,
            httpIdleTimeoutMilliseconds: httpIdleTimeoutMilliseconds,
            httpRequestTimeoutMilliseconds: httpRequestTimeoutMilliseconds,
            httpHeaderFieldBytes: httpHeaderFieldBytes,
            httpHeaderListBytes: httpHeaderListBytes,
            httpHeaderFieldCount: httpHeaderFieldCount,
            shutdownTimeoutSeconds: shutdownTimeoutSeconds,
            bearerSecretFile: bearerSecretFile,
            bearerSecret: environment["SYRINX_API_KEY"]
        )
    }

    static func secretFileReference(environment: [String: String]) throws -> String? {
        let source = environment["SYRINX_API_KEY_SOURCE"]
        let inline = environment["SYRINX_API_KEY"]
        let file = environment["SYRINX_API_KEY_FILE"]

        switch source {
        case nil:
            guard file == nil else {
                throw ConfigurationError.invalidValue(
                    key: "SYRINX_API_KEY_SOURCE",
                    value: "redacted",
                    reason: "a secret file requires SYRINX_API_KEY_SOURCE=file"
                )
            }
            if let inline, !isValidBearerValue(inline) {
                throw ConfigurationError.invalidValue(
                    key: "SYRINX_API_KEY",
                    value: "redacted",
                    reason: "must be a printable bearer value"
                )
            }
            return nil
        case "file":
            guard inline == nil else {
                throw ConfigurationError.invalidValue(
                    key: "SYRINX_API_KEY",
                    value: "redacted",
                    reason: "a direct secret cannot be combined with a secret file"
                )
            }
            guard let file, file.hasPrefix("/"), !file.contains("\0") else {
                throw ConfigurationError.invalidValue(
                    key: "SYRINX_API_KEY_FILE",
                    value: "redacted",
                    reason: "must be an absolute secret file path"
                )
            }
            return file
        default:
            throw ConfigurationError.invalidValue(
                key: "SYRINX_API_KEY_SOURCE",
                value: "redacted",
                reason: "must be file"
            )
        }
    }

    static func isValidBearerValue(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            (0x21...0x7E).contains(scalar.value)
        }
    }

    public static func load(configurationData data: Data) throws -> Self {
        try JSONDecoder().decode(ServiceConfigurationSnapshot.self, from: data).makeConfiguration()
    }

    func applyingBearerSecret(_ secret: String?) -> Self {
        Self(
            host: host,
            port: port,
            modelID: modelID,
            maxUploadBytes: maxUploadBytes,
            maxEnvelopeBytes: maxEnvelopeBytes,
            maxDurationSeconds: maxDurationSeconds,
            maxJobs: maxJobs,
            httpIdleTimeoutMilliseconds: httpIdleTimeoutMilliseconds,
            httpRequestTimeoutMilliseconds: httpRequestTimeoutMilliseconds,
            httpHeaderFieldBytes: httpHeaderFieldBytes,
            httpHeaderListBytes: httpHeaderListBytes,
            httpHeaderFieldCount: httpHeaderFieldCount,
            shutdownTimeoutSeconds: shutdownTimeoutSeconds,
            bearerSecretFile: bearerSecretFile,
            bearerSecret: secret
        )
    }

    public static func loadProcessEnvironment() throws -> Self {
        try load(environment: ProcessInfo.processInfo.environment)
    }

    private static func integer(
        _ environment: [String: String],
        key: String,
        default defaultValue: Int
    ) throws -> Int {
        guard let rawValue = environment[key] else { return defaultValue }
        guard let value = Int(rawValue) else {
            throw ConfigurationError.invalidValue(
                key: key,
                value: rawValue,
                reason: "must be an integer"
            )
        }
        return value
    }
}
