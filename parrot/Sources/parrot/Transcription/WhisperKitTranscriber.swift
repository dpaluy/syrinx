import Foundation
@preconcurrency import WhisperKit

public protocol WhisperKitModelPipeline: Sendable {
    func transcribe(_ audio: [Float]) async throws -> String
}

public protocol WhisperKitModelLoader: Sendable {
    func resolve(
        modelID: String,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws -> URL
    func load(modelFolder: URL) async throws -> any WhisperKitModelPipeline
}

struct SystemWhisperKitModelLoader: WhisperKitModelLoader {
    typealias Download = @Sendable (_ modelID: String) async throws -> URL

    private let documentsDirectory: URL
    private let download: Download?

    init(
        documentsDirectory: URL? = nil,
        download: Download? = nil
    ) {
        self.documentsDirectory = documentsDirectory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.download = download
    }

    func resolve(
        modelID: String,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws -> URL {
        let localFolder = documentsDirectory
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(modelID, isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: localFolder.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return localFolder
        }

        if let download {
            return try await download(modelID)
        }
        return try await WhisperKit.download(
            variant: modelID,
            downloadBase: nil,
            progressCallback: { progressValue in progress(progressValue.fractionCompleted) }
        )
    }

    func load(modelFolder: URL) async throws -> any WhisperKitModelPipeline {
        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            verbose: false,
            prewarm: true,
            load: true,
            download: false
        )
        return WhisperKitModelPipelineAdapter(try await WhisperKit(config))
    }
}

private final class WhisperKitModelPipelineAdapter: WhisperKitModelPipeline, @unchecked Sendable {
    private let whisperKit: WhisperKit

    init(_ whisperKit: WhisperKit) {
        self.whisperKit = whisperKit
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        let results = try await whisperKit.transcribe(audioArray: audio)
        let raw = results.map(\.text).joined(separator: " ")
        return TextOutputPolicy.sanitize(raw)
    }
}

actor WhisperKitTranscriber: Transcriber {
    let modelID: String
    private let model: TranscriptionModel
    private let loader: any WhisperKitModelLoader
    private let stateHandler: (@Sendable (ModelLifecycleState) -> Void)?
    private var pipeline: (any WhisperKitModelPipeline)?

    init(
        model: TranscriptionModel,
        loader: any WhisperKitModelLoader = SystemWhisperKitModelLoader(),
        onStateChange: (@Sendable (ModelLifecycleState) -> Void)? = nil
    ) {
        self.modelID = model.id
        self.model = model
        self.loader = loader
        self.stateHandler = onStateChange
    }

    /// Resolves the model first, then loads the resolved local folder.
    func prepare() async throws {
        if pipeline != nil { return }
        publish(.checking)

        guard let whisperKitID = model.whisperKitID else {
            let error = TranscriberError.missingEngineID
            publish(.failed(Self.errorMessage(error)))
            throw error
        }

        do {
            let stateHandler = self.stateHandler
            let folder = try await loader.resolve(modelID: whisperKitID) { progress in
                stateHandler?(.downloading(progress: progress))
            }
            publish(.downloaded)
            publish(.loading)
            pipeline = try await loader.load(modelFolder: folder)
            publish(.ready)
        } catch {
            publish(.failed(Self.errorMessage(error)))
            throw error
        }
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        if pipeline == nil { try await prepare() }
        guard let pipeline else { throw TranscriberError.notLoaded }
        return try await pipeline.transcribe(audio)
    }

    /// Strip Whisper's non-speech bracket tokens and collapse whitespace.
    static func sanitize(_ text: String) -> String {
        TextOutputPolicy.sanitize(text)
    }

    private func publish(_ state: ModelLifecycleState) {
        stateHandler?(state)
    }

    private static func errorMessage(_ error: Error) -> String {
        let message = String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Model preparation failed" : message
    }
}

enum TranscriberError: Error {
    case missingEngineID
    case notLoaded
}
