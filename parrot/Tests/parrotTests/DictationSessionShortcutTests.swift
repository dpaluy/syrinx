import XCTest
@testable import SyrinxClient

@MainActor
final class DictationSessionShortcutTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SyrinxSessionShortcutTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testIdleStartedSessionAppliesAndPersistsShortcutChoice() async throws {
        let factory = FakeHotkeyFactory()
        let preferences = AppPreferences(defaults: defaults)
        let session = makeSession(factory: factory, preferences: preferences)

        try await session.prepare()
        try session.start()

        let original = try XCTUnwrap(factory.monitors.first)
        XCTAssertTrue(original.isRunning)

        XCTAssertTrue(session.setHotkeyChoice(.rightOption))

        let replacement = try XCTUnwrap(factory.monitors.last)
        XCTAssertEqual(replacement.choice, .rightOption)
        XCTAssertFalse(original.isRunning)
        XCTAssertTrue(replacement.isRunning)
        XCTAssertEqual(preferences.hotkeyChoice, .rightOption)
        XCTAssertEqual(session.settingsState.hotkeyChoice, .rightOption)
    }

    func testFailedShortcutReplacementRollsBackToRunningPreviousChoice() async throws {
        let factory = FakeHotkeyFactory(failingChoices: [.rightCommand])
        let preferences = AppPreferences(defaults: defaults)
        let session = makeSession(factory: factory, preferences: preferences)

        try await session.prepare()
        try session.start()

        let original = try XCTUnwrap(factory.monitors.first)
        XCTAssertTrue(original.isRunning)

        XCTAssertFalse(session.setHotkeyChoice(.rightCommand))

        let restored = try XCTUnwrap(factory.monitors.last)
        XCTAssertEqual(restored.choice, .fnOrGlobe)
        XCTAssertFalse(original.isRunning)
        XCTAssertTrue(restored.isRunning)
        XCTAssertEqual(preferences.hotkeyChoice, .fnOrGlobe)
        XCTAssertEqual(session.settingsState.hotkeyChoice, .fnOrGlobe)
        XCTAssertEqual(
            session.settingsState.shortcutError,
            "Could not activate Right Command"
        )

        session.stop()
        XCTAssertFalse(restored.isRunning)
        XCTAssertEqual(restored.stopCount, 1)
    }

    func testInitialSelectedShortcutFailureFallsBackToLastWorkingChoice() async throws {
        let factory = FakeHotkeyFactory(failingChoices: [.rightCommand])
        let preferences = AppPreferences(defaults: defaults)
        preferences.hotkeyChoice = .rightOption
        let session = makeSession(factory: factory, preferences: preferences)

        XCTAssertTrue(session.setHotkeyChoice(.rightCommand))
        try await session.prepare()
        XCTAssertNoThrow(try session.start())

        let selected = try XCTUnwrap(factory.monitors[1])
        let fallback = try XCTUnwrap(factory.monitors.last)
        XCTAssertEqual(selected.choice, .rightCommand)
        XCTAssertFalse(selected.isRunning)
        XCTAssertEqual(fallback.choice, .rightOption)
        XCTAssertTrue(fallback.isRunning)
        XCTAssertEqual(preferences.hotkeyChoice, .rightOption)
        XCTAssertEqual(session.settingsState.hotkeyChoice, .rightOption)
        XCTAssertTrue(session.settingsState.shortcutError?.contains("Right Command") ?? false)

        session.stop()
        XCTAssertFalse(fallback.isRunning)
    }

    func testInitialSelectedAndFallbackFailureLeavesSessionNotStarted() async throws {
        let factory = FakeHotkeyFactory(failingChoices: [.rightCommand, .rightOption])
        let preferences = AppPreferences(defaults: defaults)
        preferences.hotkeyChoice = .rightOption
        let session = makeSession(factory: factory, preferences: preferences)

        XCTAssertTrue(session.setHotkeyChoice(.rightCommand))
        try await session.prepare()

        XCTAssertThrowsError(try session.start()) { error in
            guard case DictationSession.SessionError.shortcutRegistrationFailed = error else {
                return XCTFail("Expected shortcut registration failure")
            }
        }

        XCTAssertTrue(factory.monitors.allSatisfy { !$0.isRunning })
        XCTAssertEqual(preferences.hotkeyChoice, .rightOption)
        XCTAssertEqual(session.settingsState.hotkeyChoice, .rightOption)
        XCTAssertTrue(session.settingsState.shortcutError?.contains("restore") ?? false)
    }

    func testRuntimeReplacementAndRollbackFailureLeavesSessionNotStarted() async throws {
        let factory = FakeHotkeyFactory(startFailurePlan: [false, true, true])
        let preferences = AppPreferences(defaults: defaults)
        let session = makeSession(factory: factory, preferences: preferences)

        try await session.prepare()
        try session.start()
        XCTAssertFalse(session.setHotkeyChoice(.rightOption))

        let failedReplacement = try XCTUnwrap(factory.monitors[1])
        let failedRestoration = try XCTUnwrap(factory.monitors[2])
        XCTAssertFalse(failedReplacement.isRunning)
        XCTAssertFalse(failedRestoration.isRunning)
        XCTAssertEqual(preferences.hotkeyChoice, .fnOrGlobe)
        XCTAssertEqual(session.settingsState.hotkeyChoice, .fnOrGlobe)
        XCTAssertTrue(session.settingsState.shortcutError?.contains("restore") ?? false)

        XCTAssertNoThrow(try session.start())
        let retried = try XCTUnwrap(factory.monitors.last)
        XCTAssertTrue(retried.isRunning)
        session.stop()
    }

    private func makeSession(
        factory: FakeHotkeyFactory,
        preferences: AppPreferences
    ) -> DictationSession {
        let service = FakeLoginItemService()
        let loginItemController = LoginItemController(service: service)
        let menuBar = MenuBarController(modelID: "test-model")
        return DictationSession(
            model: TestModel.model,
            transcriber: TestTranscriber(),
            monitorFactory: { choice in factory.make(choice: choice) },
            preferences: preferences,
            loginItemController: loginItemController,
            menuBar: menuBar
        )
    }
}

private enum TestModel {
    static let model = TranscriptionModel(
        id: "test-model",
        displayName: "Test model",
        engine: .whisperKit,
        whisperKitID: "test-model",
        sizeMB: 1,
        languages: ["en"],
        recommended: false
    )
}

private struct TestTranscriber: Transcriber {
    let modelID = "test-model"

    func prepare() async throws {}

    func transcribe(_ audio: [Float]) async throws -> String {
        ""
    }
}

private enum FakeHotkeyError: Error {
    case registrationFailed
}

@MainActor
private final class FakeHotkeyFactory {
    private let failingChoices: Set<HotkeyChoice>
    private var startFailurePlan: [Bool]
    private(set) var monitors: [FakeHotkeyMonitor] = []

    init(failingChoices: Set<HotkeyChoice> = [], startFailurePlan: [Bool] = []) {
        self.failingChoices = failingChoices
        self.startFailurePlan = startFailurePlan
    }

    func make(choice: HotkeyChoice) -> FakeHotkeyMonitor {
        let shouldFailStart: Bool
        if startFailurePlan.isEmpty {
            shouldFailStart = failingChoices.contains(choice)
        } else {
            shouldFailStart = startFailurePlan.removeFirst()
        }
        let monitor = FakeHotkeyMonitor(
            choice: choice,
            shouldFailStart: shouldFailStart
        )
        monitors.append(monitor)
        return monitor
    }
}

private final class FakeHotkeyMonitor: HotkeyMonitoring {
    let choice: HotkeyChoice
    let shouldFailStart: Bool
    private(set) var isRunning = false
    private(set) var stopCount = 0

    init(choice: HotkeyChoice, shouldFailStart: Bool) {
        self.choice = choice
        self.shouldFailStart = shouldFailStart
    }

    func start(onEvent: @escaping (HotkeyMonitor.Event) -> Void) throws {
        if shouldFailStart {
            throw FakeHotkeyError.registrationFailed
        }
        isRunning = true
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }
}

private final class FakeLoginItemService: LoginItemServiceAdapter {
    var status: LoginItemStatus = .disabled

    func register() throws {
        status = .enabled
    }

    func unregister() throws {
        status = .disabled
    }
}
