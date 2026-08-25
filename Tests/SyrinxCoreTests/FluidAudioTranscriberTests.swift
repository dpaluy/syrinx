import XCTest
@testable import SyrinxCore

final class FluidAudioTranscriberTests: XCTestCase {
    func testEachProjectRequestGetsASeparateDecoderStateIdentity() async throws {
        let handler = RecordingFluidAudioHandler()
        let transcriber = FluidAudioTranscriber(handler: handler, modelID: "fake")
        let first = TranscriptionRequest(audioFile: URL(fileURLWithPath: "/tmp/first.wav"))
        let second = TranscriptionRequest(audioFile: URL(fileURLWithPath: "/tmp/second.wav"))

        _ = try await transcriber.transcribe(first)
        _ = try await transcriber.transcribe(second)

        let identities = await handler.decoderStateIdentities
        XCTAssertEqual(identities.count, 2)
        XCTAssertNotEqual(identities[0], identities[1])
    }
}

private actor RecordingFluidAudioHandler: FluidAudioRequestHandler {
    private(set) var decoderStateIdentities: [UUID] = []

    func transcribe(_ invocation: FluidAudioInvocation) async throws -> TranscriptionResult {
        decoderStateIdentities.append(invocation.decoderStateIdentity)
        return TranscriptionResult(
            text: "ok",
            duration: 1,
            processingTime: 0.1,
            modelID: "fake"
        )
    }
}
