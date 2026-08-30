import AppKit
import Foundation

@MainActor
public final class DictationSession {
    public enum SessionError: Error {
        case alreadyStarted
        case modelNotReady
        case shortcutRegistrationFailed
    }

    private let model: TranscriptionModel
    private let transcriber: any Transcriber
    private let monitorFactory: (HotkeyChoice) -> any HotkeyMonitoring
    private var monitor: any HotkeyMonitoring
    private let capture: AudioCapture
    private let overlay: RecordingOverlay
    private let menuBar: MenuBarController
    private let preferences: AppPreferences
    private let loginItemController: LoginItemController
    private let modelStateRelay: ModelStateRelay
    public let settingsState: SettingsState
    private var started = false
    private var prepared = false
    private var workingHotkeyChoice: HotkeyChoice

    private lazy var settingsWindow: SettingsWindowController = {
        SettingsWindowController(
            state: settingsState,
            loginItemController: loginItemController,
            onHotkeyChoiceChanged: { [weak self] choice in
                self?.setHotkeyChoice(choice) ?? false
            }
        )
    }()

    public init(model: TranscriptionModel) throws {
        let preferences = AppPreferences()
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
        let transcriber: any Transcriber
        switch model.engine {
        case .whisperKit:
            transcriber = WhisperKitTranscriber(model: model, onStateChange: stateHandler)
        case .parakeet:
            transcriber = try TranscriberFactory.make(model: model)
        }
        let monitor = HotkeyMonitor(choice: preferences.hotkeyChoice)
        let menuBar = MenuBarController(modelID: model.id)

        self.model = model
        self.transcriber = transcriber
        self.monitorFactory = { HotkeyMonitor(choice: $0) }
        self.monitor = monitor
        self.capture = AudioCapture()
        self.overlay = RecordingOverlay()
        self.menuBar = menuBar
        self.preferences = preferences
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
    }

    /// Dependency-injected initializer for runtime tests. It does not touch
    /// the system login item unless the supplied controller does so.
    internal init(
        model: TranscriptionModel,
        transcriber: any Transcriber,
        monitorFactory: @escaping (HotkeyChoice) -> any HotkeyMonitoring,
        preferences: AppPreferences = AppPreferences(),
        loginItemController: LoginItemController,
        menuBar: MenuBarController
    ) {
        let settingsState = SettingsState(
            model: model,
            appVersion: AppVersion.current(),
            preferences: preferences,
            loginItemStatus: loginItemController.status
        )
        self.model = model
        self.transcriber = transcriber
        self.monitorFactory = monitorFactory
        self.monitor = monitorFactory(preferences.hotkeyChoice)
        self.capture = AudioCapture()
        self.overlay = RecordingOverlay()
        self.menuBar = menuBar
        self.preferences = preferences
        self.loginItemController = loginItemController
        self.modelStateRelay = ModelStateRelay()
        self.settingsState = settingsState
        self.workingHotkeyChoice = preferences.hotkeyChoice

        capture.onLevel = { [weak overlay] level in
            overlay?.pushLevel(level)
        }
        menuBar.bind(to: settingsState)
        menuBar.setSettingsAction { [weak self] in
            self?.showSettings()
        }
    }

    public func prepare() async throws {
        if model.engine != .whisperKit {
            publishModelState(.checking)
            publishModelState(.loading)
        }
        do {
            try await transcriber.prepare()
            publishModelState(.ready)
            prepared = true
            menuBar.setModelState(.ready)
            menuBar.setHotkeyChoice(preferences.hotkeyChoice)
        } catch {
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
        guard started else { return }
        monitor.stop()
        _ = capture.stop()
        overlay.hide()
        menuBar.setStarted(false)
        menuBar.setRecording(false)
        settingsState.setHotkeyChangeAllowed(true)
        started = false
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
        settingsState.setHotkeyChangeAllowed(true)
    }

    private func publishModelState(_ state: ModelLifecycleState) {
        let sequence = modelStateRelay.nextSequence()
        settingsState.setModelState(state, sequence: sequence)
    }

    private func handle(_ event: HotkeyMonitor.Event) {
        switch event {
        case .pressed:
            do {
                try capture.start()
                settingsState.setHotkeyChangeAllowed(false)
                overlay.show(.recording)
                menuBar.setRecording(true)
            } catch {
                menuBar.setStatus("microphone unavailable")
                settingsState.setHotkeyChangeAllowed(true)
            }
        case .released:
            let samples = capture.stop()
            settingsState.setHotkeyChangeAllowed(false)
            overlay.show(.transcribing)
            menuBar.setTranscribing()
            guard UtteranceAcceptancePolicy.accepts(sampleCount: samples.count) else {
                overlay.hide()
                menuBar.setRecording(false)
                settingsState.setHotkeyChangeAllowed(true)
                return
            }

            Task { [weak self] in
                guard let self else { return }
                do {
                    let text = try await transcriber.transcribe(samples)
                    if let output = TextOutputPolicy.output(
                        for: text,
                        addTrailingSpace: preferences.addTrailingSpace
                    ) {
                        TextInjector.inject(output)
                    }
                } catch {
                    menuBar.setStatus("transcription failed")
                }
                overlay.hide()
                menuBar.setRecording(false)
                settingsState.setHotkeyChangeAllowed(true)
            }
        }
    }

    private static func errorMessage(_ error: Error) -> String {
        let message = String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Model preparation failed" : message
    }
}
