import AppKit

@MainActor
public final class SettingsWindowController: NSWindowController, NSTextViewDelegate {
    private let state: SettingsState
    private let loginItemController: LoginItemController
    private let onHotkeyChoiceChanged: (HotkeyChoice) -> Bool
    private let onModelChanged: (TranscriptionModel) -> Void
    private let activeScreenVisibleFrame: () -> NSRect?

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
        onModelChanged: @escaping (TranscriptionModel) -> Void = { _ in },
        activeScreenVisibleFrame: @escaping () -> NSRect? = {
            NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame
        }
    ) {
        self.state = state
        self.loginItemController = loginItemController ?? LoginItemController()
        self.onHotkeyChoiceChanged = onHotkeyChoiceChanged
        self.onModelChanged = onModelChanged
        self.activeScreenVisibleFrame = activeScreenVisibleFrame

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Syrinx Settings"
        window.contentMinSize = NSSize(width: 520, height: 480)
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
        let visibleFrame = activeScreenVisibleFrame()
        showWindow(nil)
        if let visibleFrame {
            centerWindow(in: visibleFrame)
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func centerWindow(in visibleFrame: NSRect) {
        guard let window else { return }

        let windowFrame = window.frame
        let centeredX = visibleFrame.midX - (windowFrame.width / 2)
        let centeredY = visibleFrame.midY - (windowFrame.height / 2)
        let maximumX = max(visibleFrame.minX, visibleFrame.maxX - windowFrame.width)
        let maximumY = max(visibleFrame.minY, visibleFrame.maxY - windowFrame.height)
        let origin = NSPoint(
            x: min(max(centeredX, visibleFrame.minX), maximumX),
            y: min(max(centeredY, visibleFrame.minY), maximumY)
        )
        window.setFrameOrigin(origin)
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
        replacementsTextView.textContainerInset = NSSize(width: 6, height: 6)
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

        for label in [versionLabel, loginItemStatusLabel] {
            label.alignment = .left
            label.lineBreakMode = .byTruncatingTail
        }
        loginItemStatusLabel.textColor = .secondaryLabelColor
        for label in [loginItemErrorLabel, shortcutErrorLabel, modelStateLabel] {
            label.alignment = .left
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        loginItemErrorLabel.textColor = .systemRed
        shortcutErrorLabel.textColor = .systemRed
        modelProgress.isIndeterminate = true
        modelProgress.controlSize = .small
        modelProgress.isDisplayedWhenStopped = false
    }

    private func configureLayout() {
        guard let contentView = window?.contentView else { return }

        let replacementsHelp = NSTextField(
            wrappingLabelWithString: "Add one replacement per line. Use spoken form => replacement."
        )
        replacementsHelp.textColor = .secondaryLabelColor
        replacementsHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        replacementsHelp.maximumNumberOfLines = 0

        let shortcutRow = makeFormRow(label: "Hold shortcut", control: hotkeyPopup)
        let outputModeRow = makeFormRow(label: "Text output", control: outputModePopup)

        let loginRow = NSStackView(views: [launchAtLoginCheckbox, loginItemStatusLabel])
        loginRow.orientation = .horizontal
        loginRow.spacing = 12
        loginRow.alignment = .centerY
        loginItemStatusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        modelPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let modelStateRow = NSStackView(views: [modelStateLabel, modelProgress])
        modelStateRow.orientation = .horizontal
        modelStateRow.spacing = 8
        modelStateRow.alignment = .top
        modelProgress.setContentHuggingPriority(.required, for: .horizontal)

        let sections = [
            makeSection(
                title: "Dictation behavior",
                views: [trailingSpaceCheckbox, spokenPunctuationCheckbox]
            ),
            makeSection(
                title: "Replacements",
                views: [replacementsHelp, replacementsScrollView]
            ),
            makeSection(
                title: "Shortcut and output",
                views: [shortcutRow, shortcutErrorLabel, outputModeRow]
            ),
            makeSection(
                title: "Permissions and startup",
                views: [loginRow, loginItemErrorLabel]
            ),
            makeSection(
                title: "Model",
                views: [modelPopup, modelStateRow]
            ),
            makeSection(title: "About", views: [versionLabel]),
        ]
        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.spacing = 24
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        for section in sections {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let documentView = NSView(frame: .zero)
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)

        let scrollView = NSScrollView(frame: .zero)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = documentView
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),

            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -28),

            replacementsScrollView.heightAnchor.constraint(equalToConstant: 120),
            modelStateLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
    }

    private func makeSection(title: String, views: [NSView]) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)

        let content = NSStackView(views: views)
        content.orientation = .vertical
        content.spacing = 8
        content.alignment = .leading
        for view in views {
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }

        let section = NSStackView(views: [titleLabel, content])
        section.orientation = .vertical
        section.spacing = 10
        section.alignment = .leading
        content.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    private func makeFormRow(label: String, control: NSView) -> NSStackView {
        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .left
        labelView.widthAnchor.constraint(equalToConstant: 124).isActive = true
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [labelView, control])
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY
        row.distribution = .fill
        return row
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
        loginItemErrorLabel.isHidden = state.loginItemOperationError == nil
        versionLabel.stringValue = "Version: \(state.appVersion)"
        modelPopup.selectItem(withTitle: Self.modelTitle(state.model))
        modelPopup.toolTip = Self.modelTitle(state.model)
        modelPopup.isEnabled = state.modelChangeAllowed
        modelStateLabel.stringValue = state.modelState.displayText
        shortcutErrorLabel.isHidden = state.shortcutError == nil

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
