import FluidAudio
import Foundation

actor FluidAudioRuntimeMetrics {
    struct Snapshot: Equatable, Sendable {
        let loadCount: Int
        let managerConstructionCount: Int

        init(loadCount: Int, managerConstructionCount: Int) {
            self.loadCount = loadCount
            self.managerConstructionCount = managerConstructionCount
        }
    }

    private var loadCount = 0
    private var managerConstructionCount = 0

    init() {}

    func recordLoad() {
        loadCount += 1
    }

    func recordManagerConstruction() {
        managerConstructionCount += 1
    }

    func snapshot() -> Snapshot {
        Snapshot(
            loadCount: loadCount,
            managerConstructionCount: managerConstructionCount
        )
    }
}

@_spi(Testing) public actor FluidAudioRuntimeTestingState {
    public static let shared = FluidAudioRuntimeTestingState()

    private var offlineModeEnabled = false

    public func reset() {
        offlineModeEnabled = false
    }

    public func recordOfflineModeEnabled() {
        offlineModeEnabled = true
    }

    public func isOfflineModeEnabled() -> Bool {
        offlineModeEnabled
    }
}

public struct FluidAudioRuntimeLoader: RuntimeLoader {
    private let metrics: FluidAudioRuntimeMetrics?

    public init() {
        metrics = nil
    }

    init(metrics: FluidAudioRuntimeMetrics) {
        self.metrics = metrics
    }

    public func load(configuration: RuntimeStartConfiguration) async throws -> any Transcriber {
        await metrics?.recordLoad()
        ModelHub.offlineMode = true
        await FluidAudioRuntimeTestingState.shared.recordOfflineModeEnabled()

        let models: AsrModels
        do {
            models = try await AsrModels.load(
                from: configuration.modelDirectory,
                configuration: AsrModels.defaultConfiguration(),
                version: .v3,
                encoderPrecision: .int8
            )
        } catch let error as DownloadError {
            if case .modelMissing = error {
                throw TranscriptionDiagnostic(
                    code: .modelMissing,
                    message: "required model files are missing"
                )
            }
            throw TranscriptionDiagnostic(
                code: .modelLoadFailed,
                message: "model loading failed"
            )
        } catch {
            throw TranscriptionDiagnostic(
                code: .modelLoadFailed,
                message: "model loading failed"
            )
        }
        let manager = AsrManager(
            config: ASRConfig(parallelChunkConcurrency: 1),
            models: models
        )
        await metrics?.recordManagerConstruction()
        guard await manager.isAvailable else {
            throw TranscriptionDiagnostic(
                code: .modelLoadFailed,
                message: "loaded model is not available"
            )
        }

        return FluidAudioTranscriber(
            handler: LiveFluidAudioRequestHandler(manager: manager),
            modelID: configuration.modelID
        )
    }
}

struct FluidAudioInvocation: Sendable {
    let request: TranscriptionRequest
    let decoderStateIdentity: UUID
}

protocol FluidAudioRequestHandler: Sendable {
    func transcribe(_ invocation: FluidAudioInvocation) async throws -> TranscriptionResult
}

struct FluidAudioTranscriber: Transcriber {
    private let handler: any FluidAudioRequestHandler
    private let modelID: String

    init(handler: any FluidAudioRequestHandler, modelID: String) {
        self.handler = handler
        self.modelID = modelID
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        do {
            var result = try await handler.transcribe(
                FluidAudioInvocation(request: request, decoderStateIdentity: UUID())
            )
            result = TranscriptionResult(
                text: result.text,
                duration: result.duration,
                processingTime: result.processingTime,
                modelID: modelID
            )
            return result
        } catch let diagnostic as TranscriptionDiagnostic {
            throw diagnostic
        } catch {
            throw TranscriptionDiagnostic(
                code: .transcriptionFailed,
                message: "transcription failed"
            )
        }
    }
}

private struct LiveFluidAudioRequestHandler: FluidAudioRequestHandler {
    let manager: AsrManager

    func transcribe(_ invocation: FluidAudioInvocation) async throws -> TranscriptionResult {
        let started = ContinuousClock.now
        var decoderState = try TdtDecoderState(decoderLayers: 2)
        let result = try await manager.transcribe(
            invocation.request.audioFile,
            decoderState: &decoderState
        )
        let processingTime = started.duration(to: .now).components
        let seconds = Double(processingTime.seconds) + Double(processingTime.attoseconds) / 1e18
        return TranscriptionResult(
            text: result.text,
            duration: result.duration,
            processingTime: seconds,
            modelID: ""
        )
    }
}
