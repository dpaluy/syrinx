import Foundation
import XCTest
@testable import SyrinxCore

final class TranscribeCommandContractTests: XCTestCase {
    func testTranscribeRequiresOneWAVArgument() async {
        let result = await CommandRunner(environment: [:]).runAsync(arguments: ["transcribe"])

        XCTAssertEqual(result.exitCode, 2)
        XCTAssertEqual(result.stderr, TranscribeCommand.usage)
    }

    func testTranscribeRejectsRemovedModelAndProbeFlags() async {
        let result = await CommandRunner(environment: [:]).runAsync(arguments: [
            "transcribe", "--model-path", "model", "--probe", "probe", "audio.wav"
        ])

        XCTAssertEqual(result.exitCode, 2)
        XCTAssertEqual(result.stderr, TranscribeCommand.usage)
    }

    func testTranscribeRejectsInvalidDeadlineAndExtraPositionals() async {
        let invalidDeadline = await CommandRunner(environment: [:]).runAsync(arguments: [
            "transcribe", "--deadline-seconds", "0", "audio.wav"
        ])
        let extra = await CommandRunner(environment: [:]).runAsync(arguments: [
            "transcribe", "audio.wav", "extra.wav"
        ])

        XCTAssertEqual(invalidDeadline.exitCode, 2)
        XCTAssertEqual(extra.exitCode, 2)
        XCTAssertEqual(invalidDeadline.stderr, TranscribeCommand.usage)
        XCTAssertEqual(extra.stderr, TranscribeCommand.usage)
    }

    func testTranscribeErrorDoesNotExposeTheInputPath() async throws {
        let input = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("syrinx-command-\(UUID().uuidString).wav")
        let path = input.path
        let result = await CommandRunner(environment: [:]).runAsync(arguments: ["transcribe", path])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertFalse(result.stderr.contains(path))
        XCTAssertFalse(result.stderr.contains("FluidAudio."))
    }

    func testTranscribeJSONUsesInjectedEngineAndSortedKeys() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("syrinx-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = StandardPaths(data: root, cache: root, logs: root)
        let engine = CommandFakeEngine()
        let command = TranscribeCommand(environment: [:], paths: paths) { _, _ in engine }

        let result = await command.run(arguments: ["--json", "--deadline-seconds", "1", "/tmp/input.wav"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.hasPrefix("{\"duration\""))
        XCTAssertEqual(result.stdout, "{\"duration\":1,\"model_id\":\"parakeet-tdt-0.6b-v3\",\"model_revision\":\"revision\",\"processing_time\":0.1,\"text\":\"ok\"}\n")
        XCTAssertEqual(engine.starts, 1)
        XCTAssertEqual(engine.drains, 1)
    }

    func testTranscribeHumanOutputUsesInjectedEngineLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("syrinx-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = StandardPaths(data: root, cache: root, logs: root)
        let engine = CommandFakeEngine()
        let command = TranscribeCommand(environment: [:], paths: paths) { _, _ in engine }

        let result = await command.run(arguments: ["/tmp/input.wav"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(
            result.stdout,
            "text: ok\nduration: 1.0\nprocessing time: 0.1\nmodel: parakeet-tdt-0.6b-v3\nmodel revision: revision\n"
        )
        XCTAssertEqual(engine.starts, 1)
        XCTAssertEqual(engine.drains, 1)
    }

    func testTranscribeDeadlinePolicyAllowsConfiguredDefaultAndExplicit3600() throws {
        let configuration = ServiceConfiguration()
        XCTAssertEqual(
            try NativeTranscriptionEngine.testingResolveDeadline(configuration: configuration, requested: nil),
            120,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            try NativeTranscriptionEngine.testingResolveDeadline(configuration: configuration, requested: 1),
            1,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            try NativeTranscriptionEngine.testingResolveDeadline(configuration: configuration, requested: 3_600),
            3_600,
            accuracy: 0.000_1
        )
        for invalid in [0.0, 3_601.0, .infinity, .nan] {
            XCTAssertThrowsError(try NativeTranscriptionEngine.testingResolveDeadline(configuration: configuration, requested: invalid))
        }
    }
}

private final class CommandFakeEngine: @unchecked Sendable, ForegroundTranscriptionEngine {
    private(set) var starts = 0
    private(set) var drains = 0

    func start() async throws { starts += 1 }

    func drain(timeout: Duration) async -> DrainResult {
        drains += 1
        return .completed
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        TranscriptionResult(
            text: "ok",
            duration: 1,
            processingTime: 0.1,
            modelID: "parakeet-tdt-0.6b-v3",
            modelRevision: "revision"
        )
    }
}
