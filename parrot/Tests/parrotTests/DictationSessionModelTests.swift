import XCTest
@testable import SyrinxClient

@MainActor
final class DictationSessionModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SyrinxSessionModelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testIdleModelChangePreparesAndPersistsSelectedWhisperModel() async throws {
        let initial = try XCTUnwrap(ModelRegistry.recommended())
        let selected = try XCTUnwrap(ModelRegistry.find("whisper-small.en"))
        let recorder = ModelPreparationRecorder()
        let factory = ModelTestTranscriberFactory { model in
            RecordingModelTranscriber(modelID: model.id, recorder: recorder)
        }
        let preferences = AppPreferences(defaults: defaults)
        let session = makeSession(
            initialModel: initial,
            initialTranscriber: factory.make(initial),
            factory: factory,
            preferences: preferences
        )
        try await session.prepare()
        try session.start()

        let changed = await session.setModel(selected)

        XCTAssertTrue(changed)
        XCTAssertEqual(session.settingsState.model.id, selected.id)
        XCTAssertEqual(preferences.selectedModelID, selected.id)
        XCTAssertEqual(session.settingsState.modelState, .ready)
        XCTAssertTrue(session.settingsState.modelChangeAllowed)
        let preparedIDs = await recorder.preparedIDs
        XCTAssertEqual(preparedIDs, [initial.id, selected.id])
    }

    func testModelChangesAreRejectedWhileRecordingOrTranscribing() async throws {
        let initial = try XCTUnwrap(ModelRegistry.recommended())
        let selected = try XCTUnwrap(ModelRegistry.find("whisper-small.en"))
        let transcriber = DeferredModelTranscriber(modelID: initial.id)
        let monitor = ModelHotkeyMonitor()
        let session = makeSession(
            initialModel: initial,
            initialTranscriber: transcriber,
            factory: ModelTestTranscriberFactory { model in
                ImmediateModelTranscriber(modelID: model.id)
            },
            preferences: AppPreferences(defaults: defaults),
            monitor: monitor,
            capture: ModelAudioCapture(results: [[0.1], [0.2]])
        )
        try await session.prepare()
        try session.start()

        monitor.send(.pressed)
        XCTAssertFalse(session.settingsState.modelChangeAllowed)
        let recordingChange = await session.setModel(selected)
        XCTAssertFalse(recordingChange)
        monitor.send(.cancel)

        monitor.send(.pressed)
        monitor.send(.released)
        let started = await waitUntil { await transcriber.callCount == 1 }
        XCTAssertTrue(started)
        XCTAssertFalse(session.settingsState.modelChangeAllowed)
        let transcribingChange = await session.setModel(selected)
        XCTAssertFalse(transcribingChange)
        monitor.send(.cancel)
        await transcriber.resolve(with: "late")

        XCTAssertNil(session.settingsState.preferences.selectedModelID)
        XCTAssertEqual(session.settingsState.model.id, initial.id)
    }

    func testSelectedModelReusesLifecycleProgressStates() async throws {
        let initial = try XCTUnwrap(ModelRegistry.recommended())
        let selected = try XCTUnwrap(ModelRegistry.find("whisper-small.en"))
        let factory = ModelTestTranscriberFactory(withState: { model, stateHandler in
            if model.id == selected.id {
                return ProgressModelTranscriber(modelID: model.id, stateHandler: stateHandler)
            }
            return ImmediateModelTranscriber(modelID: model.id)
        })
        let session = makeSession(
            initialModel: initial,
            initialTranscriber: factory.make(initial),
            factory: factory,
            preferences: AppPreferences(defaults: defaults)
        )
        try await session.prepare()
        var states: [ModelLifecycleState] = []
        session.settingsState.addObserver { states.append(session.settingsState.modelState) }

        let changed = await session.setModel(selected)

        XCTAssertTrue(changed)
        XCTAssertTrue(states.contains(.checking))
        XCTAssertTrue(states.contains(.downloading(progress: 0.4)))
        XCTAssertTrue(states.contains(.downloaded))
        XCTAssertTrue(states.contains(.loading))
        XCTAssertEqual(states.last, .ready)
    }

    func testFailedSelectedModelUsesFailureStateAndCanBeChangedAgain() async throws {
        let initial = try XCTUnwrap(ModelRegistry.recommended())
        let selected = try XCTUnwrap(ModelRegistry.find("whisper-large-v3-turbo"))
        let preferences = AppPreferences(defaults: defaults)
        let factory = ModelTestTranscriberFactory { model in
            if model.id == selected.id {
                return FailingModelTranscriber(modelID: model.id)
            }
            return ImmediateModelTranscriber(modelID: model.id)
        }
        let session = makeSession(
            initialModel: initial,
            initialTranscriber: factory.make(initial),
            factory: factory,
            preferences: preferences
        )
        try await session.prepare()
        try session.start()

        let changed = await session.setModel(selected)
        XCTAssertFalse(changed)

        XCTAssertEqual(session.settingsState.model.id, selected.id)
        XCTAssertEqual(preferences.selectedModelID, selected.id)
        if case .failed = session.settingsState.modelState {
            // Expected.
        } else {
            XCTFail("Expected selected-model preparation failure")
        }
        XCTAssertTrue(session.settingsState.modelChangeAllowed)
        XCTAssertTrue(session.settingsState.hotkeyChangeAllowed)
        XCTAssertEqual(session.phase, .idle)

        let recovered = await session.setModel(initial)
        XCTAssertTrue(recovered)
        XCTAssertEqual(session.settingsState.model.id, initial.id)
        XCTAssertEqual(session.settingsState.modelState, .ready)
    }

    func testDevelopmentParakeetModelCannotBeSelectedByShippingSession() async throws {
        let initial = try XCTUnwrap(ModelRegistry.recommended())
        let parakeet = try XCTUnwrap(ModelRegistry.find("parakeet-tdt-0.6b-v3"))
        let preferences = AppPreferences(defaults: defaults)
        let factory = ModelTestTranscriberFactory { model in
            ImmediateModelTranscriber(modelID: model.id)
        }
        let session = makeSession(
            initialModel: initial,
            initialTranscriber: factory.make(initial),
            factory: factory,
            preferences: preferences
        )
        try await session.prepare()

        let changed = await session.setModel(parakeet)
        XCTAssertFalse(changed)
        XCTAssertNil(preferences.selectedModelID)
        XCTAssertEqual(session.settingsState.model.id, initial.id)
        XCTAssertTrue(session.settingsState.selectableModels.allSatisfy { $0.engine == .whisperKit })
    }

    private func makeSession(
        initialModel: TranscriptionModel,
        initialTranscriber: any Transcriber,
        factory: ModelTestTranscriberFactory,
        preferences: AppPreferences,
        monitor: ModelHotkeyMonitor = ModelHotkeyMonitor(),
        capture: ModelAudioCapture = ModelAudioCapture(results: [])
    ) -> DictationSession {
        DictationSession(
            model: initialModel,
            transcriber: initialTranscriber,
            monitorFactory: { _ in monitor },
            capture: capture,
            preferences: preferences,
            loginItemController: LoginItemController(service: ModelLoginItemService()),
            menuBar: MenuBarController(modelID: initialModel.id),
            textOutput: ModelDiscardingOutput(),
            transcriberFactory: { model, stateHandler in
                factory.make(model, onStateChange: stateHandler)
            }
        )
    }

    private func waitUntil(_ condition: @escaping () async -> Bool) async -> Bool {
        for _ in 0..<100 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

private final class ModelTestTranscriberFactory {
    private let build: (
        TranscriptionModel,
        @escaping @Sendable (ModelLifecycleState) -> Void
    ) -> any Transcriber

    init(_ build: @escaping (TranscriptionModel) -> any Transcriber) {
        self.build = { model, _ in build(model) }
    }

    init(withState build: @escaping (
        TranscriptionModel,
        @escaping @Sendable (ModelLifecycleState) -> Void
    ) -> any Transcriber) {
        self.build = build
    }

    func make(
        _ model: TranscriptionModel,
        onStateChange: @escaping @Sendable (ModelLifecycleState) -> Void = { _ in }
    ) -> any Transcriber {
        build(model, onStateChange)
    }
}

private actor ModelPreparationRecorder {
    private(set) var preparedIDs: [String] = []

    func record(_ id: String) {
        preparedIDs.append(id)
    }
}

private struct RecordingModelTranscriber: Transcriber {
    let modelID: String
    let recorder: ModelPreparationRecorder

    func prepare() async throws {
        await recorder.record(modelID)
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        ""
    }
}

private struct ImmediateModelTranscriber: Transcriber {
    let modelID: String

    func prepare() async throws {}

    func transcribe(_ audio: [Float]) async throws -> String {
        ""
    }
}

private struct ProgressModelTranscriber: Transcriber {
    let modelID: String
    let stateHandler: @Sendable (ModelLifecycleState) -> Void

    func prepare() async throws {
        stateHandler(.downloading(progress: 0.4))
        await Task.yield()
        stateHandler(.downloaded)
        await Task.yield()
        stateHandler(.loading)
        await Task.yield()
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        ""
    }
}

private enum ModelTestError: Error {
    case preparationFailed
}

private struct FailingModelTranscriber: Transcriber {
    let modelID: String

    func prepare() async throws {
        throw ModelTestError.preparationFailed
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        ""
    }
}

private actor DeferredModelTranscriber: Transcriber {
    let modelID: String
    private var continuation: CheckedContinuation<String, Never>?
    private(set) var callCount = 0

    init(modelID: String) {
        self.modelID = modelID
    }

    func prepare() async throws {}

    func transcribe(_ audio: [Float]) async throws -> String {
        callCount += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func resolve(with text: String) {
        continuation?.resume(returning: text)
        continuation = nil
    }
}

private final class ModelAudioCapture: AudioCapturing {
    var onLevel: ((Float) -> Void)?
    private var results: [[Float]]
    private var isRecording = false

    init(results: [[Float]]) {
        self.results = results
    }

    func start() throws {
        isRecording = true
    }

    func stop() -> [Float] {
        guard isRecording else { return [] }
        isRecording = false
        return results.isEmpty ? [] : results.removeFirst()
    }
}

private final class ModelHotkeyMonitor: HotkeyMonitoring {
    let choice: HotkeyChoice = .fnOrGlobe
    private var handler: ((HotkeyMonitor.Event) -> Void)?

    func start(onEvent: @escaping (HotkeyMonitor.Event) -> Void) throws {
        handler = onEvent
    }

    func stop() {
        handler = nil
    }

    func send(_ event: HotkeyMonitor.Event) {
        handler?(event)
    }
}

private final class ModelDiscardingOutput: TextOutputting {
    func output(_ text: String) {}
}

private final class ModelLoginItemService: LoginItemServiceAdapter {
    var status: LoginItemStatus = .disabled

    func register() throws {
        status = .enabled
    }

    func unregister() throws {
        status = .disabled
    }
}
