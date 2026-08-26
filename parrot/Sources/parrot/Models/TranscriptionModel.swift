import Foundation

public enum Engine: String, Codable, Sendable {
    case whisperKit
    case parakeet
}

public struct TranscriptionModel: Codable, Sendable {
    public let id: String
    public let displayName: String
    public let engine: Engine
    /// Engine-specific identifier (e.g. "openai_whisper-base.en" for WhisperKit).
    public let whisperKitID: String?
    public let sizeMB: Int
    public let languages: [String]
    public let recommended: Bool

    public init(
        id: String,
        displayName: String,
        engine: Engine,
        whisperKitID: String?,
        sizeMB: Int,
        languages: [String],
        recommended: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.engine = engine
        self.whisperKitID = whisperKitID
        self.sizeMB = sizeMB
        self.languages = languages
        self.recommended = recommended
    }
}

struct ModelsManifest: Codable {
    let models: [TranscriptionModel]
}
