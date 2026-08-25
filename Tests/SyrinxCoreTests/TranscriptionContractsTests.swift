import XCTest
@testable import SyrinxCore

final class TranscriptionContractsTests: XCTestCase {
    func testRequestAndResultAreTransportNeutralSendableValues() {
        let request = TranscriptionRequest(audioFile: URL(fileURLWithPath: "/tmp/probe.wav"))
        let result = TranscriptionResult(
            text: "hello",
            duration: 1.5,
            processingTime: 0.25,
            modelID: "parakeet-tdt-0.6b-v3"
        )

        XCTAssertEqual(request.audioFile.path, "/tmp/probe.wav")
        XCTAssertEqual(result.text, "hello")
        XCTAssertEqual(result.modelID, "parakeet-tdt-0.6b-v3")
    }

    func testDiagnosticHasStableTypedCode() {
        let diagnostic = TranscriptionDiagnostic(
            code: .readinessProbeFailed,
            message: "the readiness probe failed"
        )

        XCTAssertEqual(diagnostic.code, .readinessProbeFailed)
        XCTAssertEqual(diagnostic.description, "readiness_probe_failed: the readiness probe failed")

        let missing = TranscriptionDiagnostic(
            code: .modelMissing,
            message: "required model files are missing"
        )
        XCTAssertEqual(missing.code.rawValue, "model_missing")
    }

    func testDiagnosticRedactsAbsolutePathsFromDescriptionAndCodableOutput() throws {
        let diagnostic = TranscriptionDiagnostic(
            code: .modelLoadFailed,
            message: "could not load model /Users/example/Library/Application Support/Syrinx/model and audio /tmp/probe.wav"
        )

        XCTAssertFalse(diagnostic.message.contains("/Users/example"))
        XCTAssertFalse(diagnostic.message.contains("/tmp/probe.wav"))
        XCTAssertFalse(diagnostic.description.contains("/Users/example"))
        XCTAssertFalse(diagnostic.description.contains("/tmp/probe.wav"))

        let data = try JSONEncoder().encode(diagnostic)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("/Users/example"))
        XCTAssertFalse(json.contains("/tmp/probe.wav"))
        XCTAssertTrue(json.contains("model_load_failed"))
    }
}
