import CoreML
import FluidAudio
import XCTest

final class FluidAudioAPIContractTests: XCTestCase {
    func testPinnedFluidAudioASRSurfaceCompiles() {
        ModelHub.offlineMode = true

        let configuration = AsrModels.defaultConfiguration()
        let asrConfiguration = ASRConfig(parallelChunkConcurrency: 1)
        let manager = AsrManager(config: asrConfiguration)
        let modelDirectory = URL(fileURLWithPath: "/tmp/parakeet-tdt-0.6b-v3", isDirectory: true)

        let load: (
            URL, MLModelConfiguration?, AsrModelVersion, ParakeetEncoderPrecision, MLComputeUnits?, ProgressHandler?
        ) async throws -> AsrModels = AsrModels.load
        _ = load
        _ = configuration
        _ = manager
        _ = modelDirectory
        _ = TdtDecoderState.self
        _ = ASRResult.self
    }

    func compileManagerTranscriptionSurface(
        manager: AsrManager,
        audioFile: URL
    ) async throws -> ASRResult {
        guard await manager.isAvailable else {
            throw ContractError.managerUnavailable
        }
        var decoderState = try TdtDecoderState(decoderLayers: 2)
        return try await manager.transcribe(audioFile, decoderState: &decoderState)
    }
}

private enum ContractError: Error {
    case managerUnavailable
}
