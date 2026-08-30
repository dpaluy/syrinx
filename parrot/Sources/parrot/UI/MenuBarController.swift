import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory`  -  no dock icon, no main window).
@MainActor
public final class MenuBarController {
    private let statusItem: NSStatusItem
    private let modelLabel: NSMenuItem
    private let stateLabel: NSMenuItem
    private let copyLastDictationItem: NSMenuItem
    private var modelID: String
    private var settingsAction: (() -> Void)?
    private var copyLastDictationAction: (() -> Void)?
    private var modelState: ModelLifecycleState?
    private var hotkeyChoice: HotkeyChoice = .fnOrGlobe
    private var isBusy = false
    private var isStarted = false

    public init(modelID: String, settingsAction: (() -> Void)? = nil) {
        self.modelID = modelID
        self.settingsAction = settingsAction
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: "not listening", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        modelLabel = NSMenuItem(title: "model: \(modelID)", action: nil, keyEquivalent: "")
        modelLabel.isEnabled = false
        menu.addItem(modelLabel)

        copyLastDictationItem = NSMenuItem(
            title: "Copy Last Dictation",
            action: #selector(copyLastDictationClicked),
            keyEquivalent: ""
        )
        copyLastDictationItem.target = self
        copyLastDictationItem.isEnabled = false
        menu.addItem(copyLastDictationItem)

        let settings = NSMenuItem(
            title: "Settings...",
            action: #selector(settingsClicked),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Syrinx",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        configureButton(recording: false)
    }

    public func setSettingsAction(_ action: (() -> Void)?) {
        settingsAction = action
    }

    public func setCopyLastDictationAction(_ action: (() -> Void)?) {
        copyLastDictationAction = action
    }

    public func setLastDictationAvailable(_ available: Bool) {
        copyLastDictationItem.isEnabled = available
    }

    public func bind(to state: SettingsState) {
        state.addObserver { [weak self, weak state] in
            guard let self, let state else { return }
            self.modelState = state.modelState
            self.hotkeyChoice = state.hotkeyChoice
            self.setModel(state.model)
            self.renderState()
        }
    }

    public func setRecording(_ recording: Bool) {
        isBusy = recording
        if recording {
            stateLabel.title = "● recording"
        } else {
            renderState()
        }
    }

    public func setTranscribing() {
        isBusy = true
        stateLabel.title = "transcribing…"
    }

    public func setStarted(_ started: Bool) {
        isStarted = started
        renderState()
    }

    public func setStatus(_ status: String) {
        isBusy = false
        stateLabel.title = status
    }

    public func setModelState(_ state: ModelLifecycleState) {
        modelState = state
        renderState()
    }

    public func setModel(_ model: TranscriptionModel) {
        modelID = model.id
        modelLabel.title = "model: \(model.id)"
    }

    public func setHotkeyChoice(_ choice: HotkeyChoice) {
        hotkeyChoice = choice
        renderState()
    }

    private func renderState() {
        guard !isBusy else { return }
        guard isStarted else {
            if let modelState, case .failed = modelState {
                stateLabel.title = modelState.displayText
            } else {
                stateLabel.title = "not listening"
            }
            return
        }
        if case .ready? = modelState {
            stateLabel.title = "ready · hold \(hotkeyChoice.displayName) to dictate"
        } else if let modelState {
            stateLabel.title = modelState.displayText
        } else {
            stateLabel.title = "ready · hold \(hotkeyChoice.displayName) to dictate"
        }
    }

    private func configureButton(recording: Bool) {
        guard let button = statusItem.button else { return }
        let image = Self.birdImage()
        image?.isTemplate = true
        button.image = image
    }

    // Inlined Lucide bird SVG. Keeping it in source means the executable has
    // no separate resource bundle to install alongside it  -  true single-binary.
    private static let birdSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M16 7h.01"/>\
    <path d="M3.4 18H12a8 8 0 0 0 8-8V7a4 4 0 0 0-7.28-2.3L2 20"/>\
    <path d="m20 7 2 .5-2 .5"/>\
    <path d="M10 18v3"/>\
    <path d="M14 17.75V21"/>\
    <path d="M7 18a6 6 0 0 0 3.84-10.61"/>\
    </svg>
    """

    private static func birdImage() -> NSImage? {
        guard let data = birdSVG.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }

    @objc private func settingsClicked() {
        settingsAction?()
    }

    @objc private func copyLastDictationClicked() {
        copyLastDictationAction?()
    }
}
