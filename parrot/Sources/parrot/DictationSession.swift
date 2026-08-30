import AppKit
import Foundation

internal protocol DictationAudioCapture: AudioCapturing {
    var onLevel: ((Float) -> Void)? { get set }
    func start() throws
    @discardableResult
    func stop() -> [Float]
}

extension AudioCapture: DictationAudioCapture {}

@MainActor
public final class DictationSession {
    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case outputting
    }

    static let maximumRecordingDuration: Duration = .seconds(60)

    public enum SessionError: Error {
        case alreadyStarted
        case modelNotReady
        case shortcutRegistrationFailed
    }

    typealias ModelTranscriberFactory = (
        TranscriptionModel,
        @escaping @Sendable (ModelLifecycleState) -> Void
    ) throws -> any Transcriber

    private var model: TranscriptionModel
    private var transcriber: any Transcriber
    private let transcriberFactory: ModelTranscriberFactory
    private let modelStateHandler: @Sendable (ModelLifecycleState) -> Void
    private let monitorFactory: (HotkeyChoice) -> any HotkeyMonitoring
    private var monitor: any HotkeyMonitoring
    private let capture: any AudioCapturing
    private let overlay: RecordingOverlay
    private let menuBar: MenuBarController
    private let preferences: AppPreferences
    private let textOutput: any TextOutputting
    private let copyText: (String) -> Void
    private let recordingLimitWait: @Sendable (Duration) async throws -> Void
    private let loginItemController: LoginItemController
    private let modelStateRelay: ModelStateRelay
    public let settingsState: SettingsState
    private var started = false
    private var prepared = false
    private var workingHotkeyChoice: HotkeyChoice
    private var recordingLimitTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var modelChangeInProgress = false
    private(set) var phase: Phase = .idle
    private(set) var sessionToken: UInt64 = 0
    private(set) var lastDictation: String?

    private lazy var settingsWindow: SettingsWindowController = {
        SettingsWindowController(
            state: settingsState,
            loginItemController: loginItemController,
            onHotkeyChoiceChanged: { [weak self] choice in
                self?.setHotkeyChoice(choice) ?? false
            },
            onModelChanged: { [weak self] model in
                Task { @MainActor [weak self] in
                    _ = await self?.setModel(model)
                }
            }
        )
    }()

    public init(
        model: TranscriptionModel,
        preferences: AppPreferences = AppPreferences()
    ) throws {
        let settingsState = SettingsState(
            model: model,
            appVersion: AppVersion.current(),
            preferences: preferences
        )
        let modelStateRelay = ModelStateRelay()
        let stateHandler: @Sendable (ModelLifecycleState) -> Void = { state in
            let sequence = modelStateRelay.nextSequence()
            Task { @MainActor in
                settingsState.setModelState(state, sequence: sequence)
            }
        }
        let transcriber = try Self.makeTranscriber(
            model: model,
            onStateChange: stateHandler
        )
        let monitor = HotkeyMonitor(choice: preferences.hotkeyChoice)
        let capture = AudioCapture()
        let menuBar = MenuBarController(modelID: model.id)

        self.model = model
        self.transcriber = transcriber
        self.transcriberFactory = Self.makeTranscriber
        self.modelStateHandler = stateHandler
        self.monitorFactory = { HotkeyMonitor(choice: $0) }
        self.monitor = monitor
        self.capture = capture
        self.overlay = RecordingOverlay()
        self.menuBar = menuBar
        self.preferences = preferences
        self.textOutput = AutomaticSpacingTextOutput(
            output: ConfiguredTextOutput(preferences: preferences)
        )
        self.copyText = ClipboardText.copy
        self.recordingLimitWait = { try await Task.sleep(for: $0) }
        self.loginItemController = LoginItemController()
        self.modelStateRelay = modelStateRelay
        self.settingsState = settingsState
        self.workingHotkeyChoice = preferences.hotkeyChoice

        capture.onLevel = { [weak overlay] level in
            overlay?.pushLevel(level)
        }
        menuBar.bind(to: settingsState)
        menuBar.setSettingsAction { [weak self] in
            self?.showSettings()
        }
        menuBar.setCopyLastDictationAction { [weak self] in
            _ = self?.copyLastDictation()
        }
    }

    /// Dependency-injected initializer for runtime tests. It does not touch
    /// the system login item unless the supplied controller does so.
    internal init(
        model: TranscriptionModel,
        transcriber: any Transcriber,
        monitorFactory: @escaping (HotkeyChoice) -> any HotkeyMonitoring,
        capture: any AudioCapturing = AudioCapture(),
        preferences: AppPreferences = AppPreferences(),
        loginItemController: LoginItemController,
        menuBar: MenuBarController,
        textOutput: (any TextOutputting)? = nil,
        copyText: @escaping (String) -> Void = ClipboardText.copy,
        recordingLimitWait: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        transcriberFactory: ModelTranscriberFactory? = nil
    ) {
        let settingsState = SettingsState(
            model: model,
            appVersion: AppVersion.current(),
            preferences: preferences,
            loginItemStatus: loginItemController.status
        )
        let modelStateRelay = ModelStateRelay()
        let stateHandler: @Sendable (ModelLifecycleState) -> Void = { state in
            let sequence = modelStateRelay.nextSequence()
            Task { @MainActor in
                settingsState.setModelState(state, sequence: sequence)
            }
        }
        self.model = model
        self.transcriber = transcriber
        self.transcriberFactory = transcriberFactory ?? Self.makeTranscriber
        self.modelStateHandler = stateHandler
        self.monitorFactory = monitorFactory
        self.monitor = monitorFactory(preferences.hotkeyChoice)
        self.capture = capture
        self.overlay = RecordingOverlay()
        self.menuBar = menuBar
        self.preferences = preferences
        self.textOutput = AutomaticSpacingTextOutput(
            output: textOutput ?? ConfiguredTextOutput(preferences: preferences)
        )
        self.copyText = copyText
        self.recordingLimitWait = recordingLimitWait
        self.loginItemController = loginItemController
        self.modelStateRelay = modelStateRelay
        self.settingsState = settingsState
        self.workingHotkeyChoice = preferences.hotkeyChoice

        capture.onLevel = { [weak overlay] level in
            overlay?.pushLevel(level)
        }
        menuBar.bind(to: settingsState)
        menuBar.setSettingsAction { [weak self] in
            self?.showSettings()
        }
        menuBar.setCopyLastDictationAction { [weak self] in
            _ = self?.copyLastDictation()
        }
    }

    public func prepare() async throws {
        setModelChangeInProgress(true)
        defer { setModelChangeInProgress(false) }
        try await prepareCurrentModel()
    }

    @discardableResult
    public func setModel(_ requestedModel: TranscriptionModel) async -> Bool {
        guard phase == .idle,
              settingsState.modelChangeAllowed,
              let selectedModel = ModelRegistry.inProcessWhisperKitModels.first(where: {
                  $0.id == requestedModel.id
              })
        else { return false }
        if selectedModel.id == model.id {
            guard !prepared || !started else { return true }
            setModelChangeInProgress(true)
            defer { setModelChangeInProgress(false) }
            do {
                if !prepared {
                    try await prepareCurrentModel()
                }
                try startIfNeeded()
                return true
            } catch {
                return false
            }
        }

        let candidate: any Transcriber
        do {
            candidate = try transcriberFactory(selectedModel, modelStateHandler)
        } catch {
            return false
        }

        setModelChangeInProgress(true)
        defer { setModelChangeInProgress(false) }
        prepared = false
        model = selectedModel
        transcriber = candidate
        preferences.selectedModelID = selectedModel.id
        settingsState.setModel(selectedModel)
        menuBar.setModel(selectedModel)

        do {
            try await prepareCurrentModel()
            try startIfNeeded()
            return true
        } catch {
            return false
        }
    }

    private func startIfNeeded() throws {
        guard !started else { return }
        do {
            try start()
        } catch {
            if settingsState.shortcutError == nil {
                settingsState.setShortcutError("Could not start listening")
            }
            menuBar.setStatus("could not start")
            throw error
        }
    }

    private func prepareCurrentModel() async throws {
        publishModelState(.checking)
        if model.engine != .whisperKit {
            publishModelState(.loading)
        }
        do {
            try await transcriber.prepare()
            publishModelState(.ready)
            prepared = true
            menuBar.setModel(model)
            menuBar.setModelState(.ready)
            menuBar.setHotkeyChoice(preferences.hotkeyChoice)
        } catch {
            prepared = false
            publishModelState(.failed(Self.errorMessage(error)))
            menuBar.setModelState(settingsState.modelState)
            throw error
        }
    }

    public func setStatus(_ status: String) {
        menuBar.setStatus(status)
    }

    public func showSettings() {
        settingsWindow.showSettings()
    }

    @discardableResult
    func copyLastDictation() -> Bool {
        guard let lastDictation else { return false }
        copyText(lastDictation)
        return true
    }

    public func start() throws {
        guard !started else { throw SessionError.alreadyStarted }
        guard prepared else { throw SessionError.modelNotReady }
        let selectedChoice = preferences.hotkeyChoice
        monitor.stop()
        do {
            try register(monitor)
            workingHotkeyChoice = selectedChoice
            markStarted(using: selectedChoice)
        } catch {
            monitor.stop()
            let fallbackChoice = workingHotkeyChoice
            let fallback = monitorFactory(fallbackChoice)
            do {
                try register(fallback)
                monitor = fallback
                preferences.hotkeyChoice = fallbackChoice
                settingsState.setHotkeyChoice(fallbackChoice)
                settingsState.setShortcutError(
                    "Could not activate \(selectedChoice.displayName); using \(fallbackChoice.displayName)"
                )
                markStarted(using: fallbackChoice)
            } catch {
                fallback.stop()
                monitor = fallback
                started = false
                preferences.hotkeyChoice = fallbackChoice
                settingsState.setHotkeyChoice(fallbackChoice)
                settingsState.setShortcutError(
                    "Could not activate \(selectedChoice.displayName); could not restore \(fallbackChoice.displayName)"
                )
                menuBar.setHotkeyChoice(fallbackChoice)
                menuBar.setModelState(settingsState.modelState)
                menuBar.setStarted(false)
                throw SessionError.shortcutRegistrationFailed
            }
        }
    }

    public func stop() {
        monitor.stop()
        invalidateCurrentSession()
        _ = capture.stop()
        setPhase(.idle)
        overlay.hide()
        menuBar.setRecording(false)
        menuBar.setStarted(false)
        started = false
    }

    public func cancel() {
        guard phase != .idle else { return }
        invalidateCurrentSession()
        _ = capture.stop()
        resetActiveSessionUI()
    }

    /// Applies a new hold shortcut while the session is idle.
    @discardableResult
    public func setHotkeyChoice(_ choice: HotkeyChoice) -> Bool {
        guard settingsState.hotkeyChangeAllowed else { return false }
        let previous = started ? workingHotkeyChoice : preferences.hotkeyChoice
        guard choice != previous else { return true }

        guard started else {
            monitor.stop()
            monitor = monitorFactory(choice)
            preferences.hotkeyChoice = choice
            settingsState.setHotkeyChoice(choice)
            settingsState.setShortcutError(nil)
            menuBar.setHotkeyChoice(choice)
            return true
        }

        monitor.stop()
        let replacement = monitorFactory(choice)
        do {
            try register(replacement)
            menuBar.clearFailure()
            monitor = replacement
            preferences.hotkeyChoice = choice
            workingHotkeyChoice = choice
            settingsState.setHotkeyChoice(choice)
            settingsState.setShortcutError(nil)
            menuBar.setHotkeyChoice(choice)
            return true
        } catch {
            replacement.stop()
            let restored = monitorFactory(previous)
            do {
                try register(restored)
                menuBar.clearFailure()
                monitor = restored
                preferences.hotkeyChoice = previous
                workingHotkeyChoice = previous
                settingsState.setHotkeyChoice(previous)
                settingsState.setShortcutError("Could not activate \(choice.displayName)")
            } catch {
                restored.stop()
                monitor = restored
                started = false
                preferences.hotkeyChoice = previous
                workingHotkeyChoice = previous
                settingsState.setHotkeyChoice(previous)
                settingsState.setShortcutError(
                    "Could not activate \(choice.displayName); could not restore \(previous.displayName)"
                )
                menuBar.setHotkeyChoice(previous)
                menuBar.setModelState(settingsState.modelState)
                menuBar.setStarted(false)
            }
            if started {
                menuBar.setStatus("shortcut failed · \(choice.displayName)")
            }
            return false
        }
    }

    private func register(_ monitor: any HotkeyMonitoring) throws {
        try monitor.start { [weak self] event in
            self?.handle(event)
        }
    }

    private func markStarted(using choice: HotkeyChoice) {
        started = true
        menuBar.setStarted(true)
        menuBar.setHotkeyChoice(choice)
        menuBar.setModelState(.ready)
        setPhase(.idle)
    }

    private func publishModelState(_ state: ModelLifecycleState) {
        let sequence = modelStateRelay.nextSequence()
        settingsState.setModelState(state, sequence: sequence)
    }

    private func handle(_ event: HotkeyMonitor.Event) {
        switch event {
        case .monitoringFailed:
            menuBar.setFailure("shortcut unavailable")
            settingsState.setShortcutError("shortcut unavailable; restart Syrinx or re-select the hotkey")
        case .pressed:
            beginRecording()
        case .released:
            guard phase == .recording else { return }
            finishRecording(token: sessionToken)
        case .cancel:
            cancel()
        }
    }

    private func beginRecording() {
        guard started, prepared, !modelChangeInProgress, phase == .idle else { return }
        let token = nextSessionToken()
        do {
            try capture.start()
            setPhase(.recording)
            overlay.show(.recording)
            menuBar.setRecording(true)
            recordingLimitTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await recordingLimitWait(Self.maximumRecordingDuration)
                } catch {
                    return
                }
                guard sessionToken == token, phase == .recording else { return }
                finishRecording(token: token)
            }
        } catch {
            menuBar.setStatus("microphone unavailable")
            setPhase(.idle)
        }
    }

    private func finishRecording(token: UInt64) {
        guard sessionToken == token, phase == .recording else { return }
        recordingLimitTask?.cancel()
        recordingLimitTask = nil
        let samples = capture.stop()
        guard UtteranceAcceptancePolicy.accepts(sampleCount: samples.count) else {
            resetActiveSessionUI()
            return
        }

        setPhase(.transcribing)
        overlay.show(.transcribing)
        menuBar.setTranscribing()
        let transcriber = self.transcriber
        transcriptionTask = Task { [weak self, transcriber] in
            do {
                let text = try await transcriber.transcribe(samples)
                guard let self,
                      sessionToken == token,
                      phase == .transcribing
                else { return }
                setPhase(.outputting)
                deliver(text)
                finishTranscription(token: token)
            } catch {
                guard let self,
                      sessionToken == token,
                      phase == .transcribing
                else { return }
                menuBar.setStatus("transcription failed")
                finishTranscription(token: token)
            }
        }
    }

    private func deliver(_ text: String) {
        let transcript = TextOutputPolicy.sanitize(text)
        guard !transcript.isEmpty,
              let output = TextOutputPolicy.output(
                  for: transcript,
                  literalReplacements: preferences.literalReplacements,
                  spokenPunctuationEnabled: preferences.spokenPunctuationEnabled
              )
        else { return }
        lastDictation = transcript
        menuBar.setLastDictationAvailable(true)
        textOutput.output(output)
    }

    private func finishTranscription(token: UInt64) {
        guard sessionToken == token,
              phase == .transcribing || phase == .outputting
        else { return }
        transcriptionTask = nil
        resetActiveSessionUI()
    }

    private func resetActiveSessionUI() {
        setPhase(.idle)
        overlay.hide()
        menuBar.setRecording(false)
    }

    private func setPhase(_ phase: Phase) {
        self.phase = phase
        settingsState.setHotkeyChangeAllowed(phase == .idle)
        settingsState.setModelChangeAllowed(phase == .idle && !modelChangeInProgress)
    }

    private func setModelChangeInProgress(_ inProgress: Bool) {
        modelChangeInProgress = inProgress
        settingsState.setModelChangeAllowed(phase == .idle && !inProgress)
    }

    private func nextSessionToken() -> UInt64 {
        sessionToken &+= 1
        return sessionToken
    }

    private func invalidateCurrentSession() {
        sessionToken &+= 1
        recordingLimitTask?.cancel()
        recordingLimitTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
    }

    private static func makeTranscriber(
        model: TranscriptionModel,
        onStateChange: @escaping @Sendable (ModelLifecycleState) -> Void
    ) throws -> any Transcriber {
        switch model.engine {
        case .whisperKit:
            return WhisperKitTranscriber(model: model, onStateChange: onStateChange)
        case .parakeet:
            return try TranscriberFactory.make(model: model)
        }
    }

    private static func errorMessage(_ error: Error) -> String {
        let message = String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Model preparation failed" : message
    }
}
