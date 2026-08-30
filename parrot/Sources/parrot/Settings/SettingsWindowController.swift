import AppKit

@MainActor
public final class SettingsWindowController: NSWindowController, NSTextViewDelegate {
    private let state: SettingsState
    private let loginItemController: LoginItemController
    private let onHotkeyChoiceChanged: (HotkeyChoice) -> Bool
    private let onModelChanged: (TranscriptionModel) -> Void

    private let trailingSpaceCheckbox = NSButton(
        checkboxWithTitle: "Add a space after dictation",
        target: nil,
        action: nil
    )
    private let spokenPunctuationCheckbox = NSButton(
        checkboxWithTitle: "Convert spoken punctuation",
        target: nil,
        action: nil
    )
    private let replacementsTextView = NSTextView(frame: .zero)
    private let replacementsScrollView = NSScrollView(frame: .zero)
    private let hotkeyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let outputModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let launchAtLoginCheckbox = NSButton(
        checkboxWithTitle: "Launch at login",
        target: nil,
        action: nil
    )
    private let loginItemStatusLabel = NSTextField(labelWithString: "")
    private let loginItemErrorLabel = NSTextField(labelWithString: "")
    private let shortcutErrorLabel = NSTextField(labelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "")
    private let modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelStateLabel = NSTextField(labelWithString: "")
    private let modelProgress = NSProgressIndicator(frame: .zero)

    public init(
        state: SettingsState,
        loginItemController: LoginItemController? = nil,
        onHotkeyChoiceChanged: @escaping (HotkeyChoice) -> Bool,
        onModelChanged: @escaping (TranscriptionModel) -> Void = { _ in }
    ) {
        self.state = state
        self.loginItemController = loginItemController ?? LoginItemController()
        self.onHotkeyChoiceChanged = onHotkeyChoiceChanged
        self.onModelChanged = onModelChanged

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Syrinx Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        configureControls()
        configureLayout()
        state.addObserver { [weak self] in
            self?.refreshUI()
        }
        refreshUI()
    }

    public required init?(coder: NSCoder) {
        fatalError("SettingsWindowController does not support storyboards")
    }

    public func showSettings() {
        state.refreshPreferences()
        let status = loginItemController.refresh()
        state.setLoginItemStatus(status, operationError: loginItemController.operationError)
        refreshUI()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func trailingSpaceChanged(_ sender: NSButton) {
        state.preferences.addTrailingSpace = sender.state == .on
        refreshUI()
    }

    @objc private func spokenPunctuationChanged(_ sender: NSButton) {
        state.preferences.spokenPunctuationEnabled = sender.state == .on
        refreshUI()
    }

    public func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === replacementsTextView else { return }
        state.preferences.literalReplacements = LiteralReplacementSettingsText.decode(
            replacementsTextView.string
        )
    }

    @objc private func hotkeyChanged(_ sender: NSPopUpButton) {
        guard state.hotkeyChangeAllowed,
              sender.indexOfSelectedItem >= 0,
              sender.indexOfSelectedItem < HotkeyChoice.allCases.count
        else {
            refreshUI()
            return
        }

        let choice = HotkeyChoice.allCases[sender.indexOfSelectedItem]
        guard onHotkeyChoiceChanged(choice) else {
            refreshUI()
            return
        }
        state.setHotkeyChoice(choice)
        refreshUI()
    }

    @objc private func outputModeChanged(_ sender: NSPopUpButton) {
        guard sender.indexOfSelectedItem >= 0,
              sender.indexOfSelectedItem < TextOutputMode.allCases.count
        else {
            refreshUI()
            return
        }
        state.preferences.textOutputMode = TextOutputMode.allCases[sender.indexOfSelectedItem]
        refreshUI()
    }

    @objc private func modelChanged(_ sender: NSPopUpButton) {
        guard state.modelChangeAllowed,
              sender.indexOfSelectedItem >= 0,
              sender.indexOfSelectedItem < state.selectableModels.count
        else {
            refreshUI()
            return
        }
        onModelChanged(state.selectableModels[sender.indexOfSelectedItem])
        refreshUI()
    }

    @objc private func launchAtLoginChanged(_ sender: NSButton) {
        let status = loginItemController.setEnabled(sender.state == .on)
        state.setLoginItemStatus(status, operationError: loginItemController.operationError)
        refreshUI()
    }

    private func configureControls() {
        trailingSpaceCheckbox.target = self
        trailingSpaceCheckbox.action = #selector(trailingSpaceChanged(_:))

        spokenPunctuationCheckbox.target = self
        spokenPunctuationCheckbox.action = #selector(spokenPunctuationChanged(_:))

        replacementsTextView.delegate = self
        replacementsTextView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        replacementsTextView.isRichText = false
        replacementsTextView.isAutomaticQuoteSubstitutionEnabled = false
        replacementsTextView.isAutomaticDashSubstitutionEnabled = false
        replacementsTextView.isAutomaticSpellingCorrectionEnabled = false
        replacementsTextView.isHorizontallyResizable = false
        replacementsTextView.isVerticallyResizable = true
        replacementsTextView.textContainer?.widthTracksTextView = true
        replacementsScrollView.borderType = .bezelBorder
        replacementsScrollView.hasVerticalScroller = true
        replacementsScrollView.documentView = replacementsTextView

        hotkeyPopup.addItems(withTitles: HotkeyChoice.allCases.map(\.displayName))
        hotkeyPopup.target = self
        hotkeyPopup.action = #selector(hotkeyChanged(_:))

        outputModePopup.addItems(withTitles: TextOutputMode.allCases.map(\.displayName))
        outputModePopup.target = self
        outputModePopup.action = #selector(outputModeChanged(_:))

        modelPopup.addItems(withTitles: state.selectableModels.map(Self.modelTitle))
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged(_:))

        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(launchAtLoginChanged(_:))

        for label in [versionLabel, modelStateLabel, loginItemStatusLabel] {
            label.alignment = .left
            label.lineBreakMode = .byTruncatingTail
        }
        loginItemErrorLabel.alignment = .left
        loginItemErrorLabel.textColor = .systemRed
        loginItemErrorLabel.lineBreakMode = .byTruncatingTail
        shortcutErrorLabel.alignment = .left
        shortcutErrorLabel.textColor = .systemRed
        shortcutErrorLabel.lineBreakMode = .byTruncatingTail
        modelProgress.isIndeterminate = true
        modelProgress.controlSize = .small
        modelProgress.isDisplayedWhenStopped = false
    }

    private func configureLayout() {
        guard let contentView = window?.contentView else { return }

        let settingsHeader = NSTextField(labelWithString: "Settings")
        settingsHeader.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        let replacementsLabel = NSTextField(labelWithString: "Literal replacements")
        let replacementsHelp = NSTextField(
            wrappingLabelWithString: "Use one line for each replacement: spoken form => replacement"
        )
        replacementsHelp.textColor = .secondaryLabelColor
        replacementsHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let shortcutRow = NSStackView(views: [
            NSTextField(labelWithString: "Hold shortcut"),
            hotkeyPopup,
        ])
        shortcutRow.orientation = .horizontal
        shortcutRow.spacing = 12
        shortcutRow.alignment = .centerY
        shortcutRow.distribution = .fill
        hotkeyPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let outputModeRow = NSStackView(views: [
            NSTextField(labelWithString: "Text output"),
            outputModePopup,
        ])
        outputModeRow.orientation = .horizontal
        outputModeRow.spacing = 12
        outputModeRow.alignment = .centerY
        outputModeRow.distribution = .fill
        outputModePopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let loginRow = NSStackView(views: [launchAtLoginCheckbox, loginItemStatusLabel])
        loginRow.orientation = .horizontal
        loginRow.spacing = 12
        loginRow.alignment = .centerY
        loginItemStatusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let modelHeader = NSTextField(labelWithString: "Model")
        modelHeader.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        modelPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let modelStateRow = NSStackView(views: [modelStateLabel, modelProgress])
        modelStateRow.orientation = .horizontal
        modelStateRow.spacing = 8
        modelStateRow.alignment = .centerY
        modelProgress.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [
            settingsHeader,
            trailingSpaceCheckbox,
            spokenPunctuationCheckbox,
            replacementsLabel,
            replacementsScrollView,
            replacementsHelp,
            shortcutRow,
            shortcutErrorLabel,
            outputModeRow,
            loginRow,
            loginItemErrorLabel,
            NSView(),
            versionLabel,
            modelHeader,
            modelPopup,
            modelStateRow,
        ])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            replacementsScrollView.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            replacementsScrollView.heightAnchor.constraint(equalToConstant: 64),
            replacementsHelp.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            shortcutRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            outputModeRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            loginRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            modelPopup.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            modelStateRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            modelStateLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
    }

    private static func modelTitle(_ model: TranscriptionModel) -> String {
        "\(model.displayName) (\(model.id), \(model.sizeMB) MB)"
    }

    private func refreshUI() {
        trailingSpaceCheckbox.state = state.preferences.addTrailingSpace ? .on : .off
        spokenPunctuationCheckbox.state = state.preferences.spokenPunctuationEnabled ? .on : .off
        if !isEditingReplacements {
            loadReplacementsText()
        }
        hotkeyPopup.selectItem(withTitle: state.hotkeyChoice.displayName)
        hotkeyPopup.isEnabled = state.hotkeyChangeAllowed
        outputModePopup.selectItem(withTitle: state.preferences.textOutputMode.displayName)
        shortcutErrorLabel.stringValue = state.shortcutError ?? ""
        launchAtLoginCheckbox.state = state.loginItemStatus == .enabled || state.loginItemStatus == .requiresApproval ? .on : .off
        loginItemStatusLabel.stringValue = state.loginItemStatus.displayText
        loginItemErrorLabel.stringValue = state.loginItemOperationError.map { "Error: \($0)" } ?? ""
        versionLabel.stringValue = "Version: \(state.appVersion)"
        modelPopup.selectItem(withTitle: Self.modelTitle(state.model))
        modelPopup.isEnabled = state.modelChangeAllowed
        modelStateLabel.stringValue = state.modelState.displayText

        if case .downloading(let progress) = state.modelState, let progress {
            modelProgress.isIndeterminate = false
            modelProgress.doubleValue = max(0, min(1, progress)) * 100
            modelProgress.maxValue = 100
            modelProgress.startAnimation(nil)
        } else if case .downloading = state.modelState {
            modelProgress.isIndeterminate = true
            modelProgress.startAnimation(nil)
        } else {
            modelProgress.stopAnimation(nil)
        }
    }

    private var isEditingReplacements: Bool {
        replacementsTextView.window?.firstResponder === replacementsTextView
    }

    private func loadReplacementsText() {
        let replacementsText = LiteralReplacementSettingsText.encode(
            state.preferences.literalReplacements
        )
        if replacementsTextView.string != replacementsText {
            replacementsTextView.string = replacementsText
        }
    }
}
