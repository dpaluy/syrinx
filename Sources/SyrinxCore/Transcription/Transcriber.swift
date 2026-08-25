import Foundation

public struct TranscriptionRequest: Equatable, Sendable {
    public let audioFile: URL
    public let deadline: TimeInterval?

    private let descriptorProvider: (@Sendable () throws -> Int32)?

    public init(audioFile: URL, deadline: TimeInterval? = nil) {
        self.audioFile = audioFile
        self.deadline = deadline
        descriptorProvider = nil
    }

    init(
        audioFile: URL,
        deadline: TimeInterval?,
        descriptorProvider: (@Sendable () throws -> Int32)?
    ) {
        self.audioFile = audioFile
        self.deadline = deadline
        self.descriptorProvider = descriptorProvider
    }

    init(uploadedFile: UploadedFile, deadline: TimeInterval? = nil) {
        self.init(
            audioFile: uploadedFile.url,
            deadline: deadline,
            descriptorProvider: { try uploadedFile.openReadOnlyDescriptor() }
        )
    }

    func withAudioAccess<Result: Sendable>(
        _ operation: @escaping @Sendable (AudioFileAccess) async throws -> Result
    ) async throws -> Result {
        if let descriptorProvider {
            let descriptor = try descriptorProvider()
            let access = try AudioFileAccess.openReadOnly(fileDescriptor: descriptor)
            return try await operation(access)
        }

        let access = try AudioFileAccess.openReadOnlyRegular(fileURL: audioFile)
        return try await operation(access)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.audioFile == rhs.audioFile && lhs.deadline == rhs.deadline
    }
}

public struct TranscriptionResult: Codable, Equatable, Sendable {
    public let text: String
    public let duration: TimeInterval
    public let processingTime: TimeInterval
    public let modelID: String
    public let modelRevision: String

    public var canonicalModelID: String { modelID }

    public init(
        text: String,
        duration: TimeInterval,
        processingTime: TimeInterval,
        modelID: String,
        modelRevision: String = ""
    ) {
        self.text = text
        self.duration = duration
        self.processingTime = processingTime
        self.modelID = modelID
        self.modelRevision = modelRevision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        processingTime = try container.decode(TimeInterval.self, forKey: .processingTime)
        modelID = try container.decode(String.self, forKey: .modelID)
        modelRevision = try container.decodeIfPresent(String.self, forKey: .modelRevision) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(duration, forKey: .duration)
        try container.encode(processingTime, forKey: .processingTime)
        try container.encode(modelID, forKey: .modelID)
        try container.encode(modelRevision, forKey: .modelRevision)
    }

    enum CodingKeys: String, CodingKey {
        case text
        case duration
        case processingTime = "processing_time"
        case modelID = "model_id"
        case modelRevision = "model_revision"
    }
}

public struct TranscriptionDiagnostic: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    public enum Code: String, Codable, Equatable, Sendable {
        case admissionLimitReached = "admission_limit_reached"
        case draining
        case configurationConflict = "configuration_conflict"
        case modelLoadFailed = "model_load_failed"
        case modelMissing = "model_missing"
        case readinessProbeFailed = "readiness_probe_failed"
        case runtimeUnavailable = "runtime_unavailable"
        case transcriptionFailed = "transcription_failed"
        case inputRejected = "input_rejected"
        case cancelled
        case deadlineExceeded = "deadline_exceeded"
        case drainTimeout = "drain_timeout"
        case invalidDeadline = "invalid_deadline"
    }

    public let code: Code
    public let message: String

    public init(code: Code, message: String) {
        self.code = code
        self.message = Self.sanitize(message)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            code: container.decode(Code.self, forKey: .code),
            message: container.decode(String.self, forKey: .message)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(Self.sanitize(message), forKey: .message)
    }

    public var description: String {
        "\(code.rawValue): \(Self.sanitize(message))"
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case message
    }

    private static func sanitize(_ value: String) -> String {
        var sanitized = ""
        let characters = Array(value)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            let isPathBoundary = index == 0 || characters[index - 1].isWhitespace || ":([{=,;\"'".contains(characters[index - 1])
            if character == "/" && isPathBoundary {
                sanitized += "[path]"
                repeat {
                    index += 1
                } while index < characters.count && characters[index] != "\n"
            } else {
                sanitized.append(character)
                index += 1
            }
        }

        return sanitized
    }
}

public protocol Transcriber: Sendable {
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult
}
