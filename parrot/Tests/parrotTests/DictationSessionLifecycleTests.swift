import XCTest
@testable import SyrinxClient

@MainActor
final class DictationSessionLifecycleTests: XCTestCase {
    func testMissingPermissionStopsAndBlocksRecordingUntilRecovery() async throws {
        let capture = LifecycleAudioCapture(results: [[Float](repeating: 0.1, count: 4_800)])
        let monitor = LifecycleHotkeyMonitor()
        let session = makeSession(
            transcriber: CountingSessionTranscriber(text: "blocked"),
            output: LifecycleRecordingOutput(),
            capture: capture,
            monitor: monitor
        )
        try await session.prepare()
        try session.start()

        session.updatePermissions(SyrinxPermissionState(
            microphone: .denied,
            accessibility: .granted
        ))
        monitor.send(.pressed)

        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(capture.startCount, 0)
        XCTAssertEqual(
            session.settingsState.recordingUnavailableReason,
            "Microphone permission required"
        )

        session.updatePermissions(.granted)
        try session.resumeAfterPermissionRecovery()
        monitor.send(.pressed)

        XCTAssertTrue(monitor.isRunning)
        XCTAssertEqual(session.phase, .recording)
        XCTAssertEqual(capture.startCount, 1)
    }

    func testCancelDuringTranscriptionSuppressesLateResult() async throws {
        let transcriber = DeferredSessionTranscriber()
        let output = LifecycleRecordingOutput()
        let capture = LifecycleAudioCapture(results: [[Float](repeating: 0.1, count: 4_800)])
        let monitor = LifecycleHotkeyMonitor()
        let session = makeSession(
            transcriber: transcriber,
            output: output,
            capture: capture,
            monitor: monitor
        )
        try await session.prepare()
        try session.start()

        monitor.send(.pressed)
        monitor.send(.released)
        let transcriptionStarted = await waitUntil { await transcriber.callCount == 1 }
        XCTAssertTrue(transcriptionStarted)
        XCTAssertEqual(session.phase, .transcribing)
        XCTAssertFalse(session.settingsState.hotkeyChangeAllowed)

        monitor.send(.cancel)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertTrue(session.settingsState.hotkeyChangeAllowed)
        await transcriber.resolve(call: 0, with: "late result")
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertTrue(output.values.isEmpty)
        XCTAssertNil(session.lastDictation)
    }

    func testNewDictationCannotReceiveOlderSessionResult() async throws {
        let transcriber = DeferredSessionTranscriber()
        let output = LifecycleRecordingOutput()
        let capture = LifecycleAudioCapture(results: [
            [Float](repeating: 0.1, count: 4_800),
            [Float](repeating: 0.2, count: 4_800),
        ])
        let monitor = LifecycleHotkeyMonitor()
        let session = makeSession(
            transcriber: transcriber,
            output: output,
            capture: capture,
            monitor: monitor
        )
        try await session.prepare()
        try session.start()

        monitor.send(.pressed)
        let firstToken = session.sessionToken
        monitor.send(.released)
        let firstStarted = await waitUntil { await transcriber.callCount == 1 }
        XCTAssertTrue(firstStarted)
        monitor.send(.cancel)
        let canceledToken = session.sessionToken
        XCTAssertGreaterThan(canceledToken, firstToken)

        monitor.send(.pressed)
        XCTAssertGreaterThan(session.sessionToken, canceledToken)
        monitor.send(.released)
        let secondStarted = await waitUntil { await transcriber.callCount == 2 }
        XCTAssertTrue(secondStarted)
        await transcriber.resolve(call: 1, with: "new result")
        let newResultDelivered = await waitUntil { output.values == ["new result"] }
        XCTAssertTrue(newResultDelivered)
        await transcriber.resolve(call: 0, with: "old result")
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(output.values, ["new result"])
        XCTAssertEqual(session.lastDictation, "new result")
        XCTAssertEqual(session.phase, .idle)
    }

    func testRecordingLimitStopsAndTranscribesExactlyOnce() async throws {
        XCTAssertEqual(DictationSession.maximumRecordingDuration, .seconds(60))
        let limit = RecordingLimitGate()
        let transcriber = CountingSessionTranscriber(text: "limited")
        let output = LifecycleRecordingOutput()
        let capture = LifecycleAudioCapture(results: [[Float](repeating: 0.1, count: 4_800)])
        let monitor = LifecycleHotkeyMonitor()
        let session = makeSession(
            transcriber: transcriber,
            output: output,
            capture: capture,
            monitor: monitor,
            recordingLimitWait: { _ in await limit.wait() }
        )
        var outputPhases: [DictationSession.Phase] = []
        output.onOutput = { outputPhases.append(session.phase) }
        try await session.prepare()
        try session.start()

        monitor.send(.pressed)
        XCTAssertEqual(session.phase, .recording)
        let limitIsWaiting = await waitUntil { await limit.isWaiting }
        XCTAssertTrue(limitIsWaiting)
        await limit.fire()
        let transcriptionStarted = await waitUntil { await transcriber.callCount == 1 }
        XCTAssertTrue(transcriptionStarted)
        monitor.send(.released)
        let resultDelivered = await waitUntil { output.values == ["limited"] }
        XCTAssertTrue(resultDelivered)
        try await Task.sleep(for: .milliseconds(30))

        let transcriptionCount = await transcriber.callCount
        XCTAssertEqual(transcriptionCount, 1)
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertEqual(outputPhases, [.outputting])
        XCTAssertEqual(session.phase, .idle)
    }

    func testCancelDuringRecordingDiscardsAudioWithoutTranscribing() async throws {
        let transcriber = CountingSessionTranscriber(text: "must not appear")
        let output = LifecycleRecordingOutput()
        let capture = LifecycleAudioCapture(results: [[Float](repeating: 0.1, count: 4_800)])
        let monitor = LifecycleHotkeyMonitor()
        let session = makeSession(
            transcriber: transcriber,
            output: output,
            capture: capture,
            monitor: monitor
        )
        try await session.prepare()
        try session.start()

        monitor.send(.pressed)
        monitor.send(.cancel)
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(capture.stopCount, 1)
        let transcriptionCount = await transcriber.callCount
        XCTAssertEqual(transcriptionCount, 0)
        XCTAssertTrue(output.values.isEmpty)
        XCTAssertTrue(session.settingsState.hotkeyChangeAllowed)
    }

    func testStopInvalidatesRecordingAndTranscriptionAndReturnsToIdle() async throws {
        let transcriber = DeferredSessionTranscriber()
        let output = LifecycleRecordingOutput()
        let capture = LifecycleAudioCapture(results: [
            [Float](repeating: 0.1, count: 4_800),
            [Float](repeating: 0.2, count: 4_800),
        ])
        let monitor = LifecycleHotkeyMonitor()
        let session = makeSession(
            transcriber: transcriber,
            output: output,
            capture: capture,
            monitor: monitor
        )
        try await session.prepare()
        try session.start()

        monitor.send(.pressed)
        session.stop()
        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(monitor.isRunning)
        XCTAssertTrue(session.settingsState.hotkeyChangeAllowed)

        try session.start()
        monitor.send(.pressed)
        monitor.send(.released)
        let transcriptionStarted = await waitUntil { await transcriber.callCount == 1 }
        XCTAssertTrue(transcriptionStarted)
        session.stop()
        await transcriber.resolve(call: 0, with: "stopped result")
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(monitor.isRunning)
        XCTAssertTrue(output.values.isEmpty)
        XCTAssertTrue(session.settingsState.hotkeyChangeAllowed)
    }

    private func makeSession(
        transcriber: any Transcriber,
        output: any TextOutputting,
        capture: LifecycleAudioCapture,
        monitor: LifecycleHotkeyMonitor,
        recordingLimitWait: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) -> DictationSession {
        DictationSession(
            model: LifecycleTestModel.model,
            transcriber: transcriber,
            monitorFactory: { _ in monitor },
            capture: capture,
            loginItemController: LoginItemController(service: LifecycleLoginItemService()),
            menuBar: MenuBarController(modelID: LifecycleTestModel.model.id),
            textOutput: output,
            recordingLimitWait: recordingLimitWait
        )
    }

    private func waitUntil(
        _ condition: @escaping () async -> Bool
    ) async -> Bool {
        for _ in 0..<100 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

private enum LifecycleTestModel {
    static let model = TranscriptionModel(
        id: "lifecycle-test",
        displayName: "Lifecycle test",
        engine: .whisperKit,
        whisperKitID: "lifecycle-test",
        sizeMB: 1,
        languages: ["en"],
        recommended: false
    )
}

private final class LifecycleRecordingOutput: TextOutputting {
    var values: [String] = []
    var onOutput: (() -> Void)?

    func output(_ text: String) {
        values.append(text)
        onOutput?()
    }
}

private final class LifecycleAudioCapture: AudioCapturing {
    var onLevel: ((Float) -> Void)?
    private var results: [[Float]]
    private var isRecording = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(results: [[Float]]) {
        self.results = results
    }

    func start() throws {
        isRecording = true
        startCount += 1
    }

    func stop() -> [Float] {
        guard isRecording else { return [] }
        isRecording = false
        stopCount += 1
        return results.isEmpty ? [] : results.removeFirst()
    }
}

private final class LifecycleHotkeyMonitor: HotkeyMonitoring {
    let choice: HotkeyChoice = .fnOrGlobe
    private var handler: ((HotkeyMonitor.Event) -> Void)?
    private(set) var isRunning = false

    func start(onEvent: @escaping (HotkeyMonitor.Event) -> Void) throws {
        handler = onEvent
        isRunning = true
    }

    func stop() {
        handler = nil
        isRunning = false
    }

    func send(_ event: HotkeyMonitor.Event) {
        handler?(event)
    }
}

private actor DeferredSessionTranscriber: Transcriber {
    let modelID = LifecycleTestModel.model.id
    private var continuations: [CheckedContinuation<String, Never>?] = []
    var callCount: Int { continuations.count }

    func prepare() async throws {}

    func transcribe(_ audio: [Float]) async throws -> String {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resolve(call index: Int, with text: String) {
        guard continuations.indices.contains(index), let continuation = continuations[index] else {
            return
        }
        continuations[index] = nil
        continuation.resume(returning: text)
    }
}

private actor CountingSessionTranscriber: Transcriber {
    let modelID = LifecycleTestModel.model.id
    let text: String
    private(set) var callCount = 0

    init(text: String) {
        self.text = text
    }

    func prepare() async throws {}

    func transcribe(_ audio: [Float]) async throws -> String {
        callCount += 1
        return text
    }
}

private actor RecordingLimitGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    func wait() async {
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func fire() {
        continuation?.resume()
        continuation = nil
        isWaiting = false
    }
}

private final class LifecycleLoginItemService: LoginItemServiceAdapter {
    var status: LoginItemStatus = .disabled

    func register() throws {
        status = .enabled
    }

    func unregister() throws {
        status = .disabled
    }
}
