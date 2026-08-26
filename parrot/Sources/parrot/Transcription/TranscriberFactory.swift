import Foundation

public enum TranscriberFactory {
    public static func make(
        model: TranscriptionModel,
        parakeetURL: String = "http://127.0.0.1:5092",
        parakeetAPIKey: String? = nil
    ) throws -> any Transcriber {
        switch model.engine {
        case .whisperKit:
            return WhisperKitTranscriber(model: model)
        case .parakeet:
            let configuration = try ParakeetConfiguration(
                urlString: parakeetURL,
                apiKey: parakeetAPIKey
            )
            let adapter = ParakeetHTTPAdapter(configuration: configuration)
            return ParakeetTranscriber(modelID: model.id, adapter: adapter)
        }
    }
}
