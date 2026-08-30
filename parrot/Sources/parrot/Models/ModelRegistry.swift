import Foundation

/// Built-in transcription model registry.
///
/// The model list lives directly in source rather than as a JSON resource so
/// the binary stays self-contained  -  no `Bundle.module` lookup, no per-target
/// resource bundle to ship alongside the executable.
public enum ModelRegistry {
    public static let shared: [TranscriptionModel] = [
        TranscriptionModel(
            id: "whisper-base.en",
            displayName: "Whisper Base (English)",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-base.en",
            sizeMB: 145,
            languages: ["en"],
            recommended: true
        ),
        TranscriptionModel(
            id: "whisper-large-v3-turbo",
            displayName: "Whisper Large v3 Turbo",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-large-v3-v20240930_turbo",
            sizeMB: 1620,
            languages: ["multi"],
            recommended: false
        ),
        TranscriptionModel(
            id: "whisper-small.en",
            displayName: "Whisper Small (English)",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-small.en",
            sizeMB: 488,
            languages: ["en"],
            recommended: false
        ),
        TranscriptionModel(
            id: "parakeet-tdt-0.6b-v3",
            displayName: "Parakeet TDT 0.6B v3 (local service)",
            engine: .parakeet,
            whisperKitID: nil,
            sizeMB: 670,
            languages: ["en"],
            recommended: false
        ),
    ]

    /// Models that the shipping app can load fully in process.
    public static let inProcessWhisperKitModels: [TranscriptionModel] = shared.filter {
        $0.engine == .whisperKit && $0.whisperKitID != nil
    }

    public static func find(_ id: String) -> TranscriptionModel? {
        shared.first { $0.id == id }
    }

    public static func recommended() -> TranscriptionModel? {
        shared.first { $0.recommended } ?? shared.first
    }

    /// Resolves a persisted shipping-app choice without exposing service-backed
    /// development models. An absent or invalid choice keeps recommended behavior.
    public static func preferredInProcessModel(selectedID: String?) -> TranscriptionModel? {
        if let selectedID,
           let selected = inProcessWhisperKitModels.first(where: { $0.id == selectedID }) {
            return selected
        }
        return inProcessWhisperKitModels.first(where: { $0.recommended })
            ?? inProcessWhisperKitModels.first
    }
}
