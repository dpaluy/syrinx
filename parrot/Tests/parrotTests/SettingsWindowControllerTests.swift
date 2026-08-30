import AppKit
import XCTest
@testable import SyrinxClient

@MainActor
final class SettingsWindowControllerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SyrinxSettingsWindowTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        _ = NSApplication.shared
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        suiteName = nil
        defaults = nil
        super.tearDown()
    }

    func testCombinedSettingsLayoutKeepsInteractiveControlsInsideContentBounds() throws {
        let preferences = AppPreferences(defaults: defaults)
        let state = SettingsState(model: TestModel.model, preferences: preferences)
        let controller = SettingsWindowController(
            state: state,
            loginItemController: LoginItemController(service: FakeLoginItemService()),
            onHotkeyChoiceChanged: { _ in true }
        )
        controller.showSettings()

        let window = try XCTUnwrap(controller.window)
        let contentView = try XCTUnwrap(window.contentView)
        contentView.layoutSubtreeIfNeeded()
        let controls = interactiveControls(in: contentView)

        XCTAssertGreaterThanOrEqual(contentView.bounds.height, 540)
        XCTAssertEqual(controls.count, 6)
        for control in controls {
            let frame = control.convert(control.bounds, to: contentView)
            XCTAssertGreaterThan(frame.width, 0, "Expected usable width for \(control)")
            XCTAssertGreaterThan(frame.height, 0, "Expected usable height for \(control)")
            XCTAssertTrue(
                contentView.bounds.contains(frame),
                "Expected \(control) frame \(frame) inside content bounds \(contentView.bounds)"
            )
        }
    }

    func testSettingsLayoutGroupsRelatedControlsIntoNamedSections() throws {
        let controller = makeController()
        controller.showSettings()

        let window = try XCTUnwrap(controller.window)
        let labels = textLabels(in: try XCTUnwrap(window.contentView)).map(\.stringValue)

        for title in [
            "Dictation behavior",
            "Replacements",
            "Shortcut and output",
            "Permissions and startup",
            "Model",
            "About",
        ] {
            XCTAssertTrue(labels.contains(title), "Expected a \(title) section")
        }
    }

    func testSettingsSectionsUseLeftToRightLayoutAndAvailableWidth() throws {
        let controller = makeController()
        controller.showSettings()

        let window = try XCTUnwrap(controller.window)
        let contentView = try XCTUnwrap(window.contentView)
        contentView.layoutSubtreeIfNeeded()
        let sectionTitles = Set([
            "Dictation behavior",
            "Replacements",
            "Shortcut and output",
            "Permissions and startup",
            "Model",
            "About",
        ])
        let titleFrames = textLabels(in: contentView)
            .filter { sectionTitles.contains($0.stringValue) }
            .map { $0.convert($0.bounds, to: contentView) }
        let replacementsEditor = try XCTUnwrap(
            scrollViews(in: contentView).first { $0.documentView is NSTextView }
        )
        let editorFrame = replacementsEditor.convert(replacementsEditor.bounds, to: contentView)

        XCTAssertEqual(titleFrames.count, sectionTitles.count)
        for frame in titleFrames {
            XCTAssertLessThanOrEqual(frame.minX, 40)
        }
        XCTAssertLessThanOrEqual(editorFrame.minX, 40)
        XCTAssertGreaterThan(editorFrame.width, contentView.bounds.width - 80)
    }

    func testMinimumWindowSizeKeepsContentReachableThroughScrolling() throws {
        let controller = makeController()
        controller.showSettings()

        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.styleMask.contains(.resizable))
        window.setContentSize(window.contentMinSize)

        let contentView = try XCTUnwrap(window.contentView)
        contentView.layoutSubtreeIfNeeded()
        let scrollView = try XCTUnwrap(firstSubview(of: NSScrollView.self, in: contentView))
        let documentView = try XCTUnwrap(scrollView.documentView)
        documentView.layoutSubtreeIfNeeded()

        XCTAssertTrue(scrollView.hasVerticalScroller)
        XCTAssertGreaterThan(documentView.bounds.height, scrollView.contentView.bounds.height)
        for control in interactiveControls(in: documentView) {
            let frame = control.convert(control.bounds, to: documentView)
            XCTAssertGreaterThan(frame.width, 0, "Expected usable width for \(control)")
            XCTAssertGreaterThan(frame.height, 0, "Expected usable height for \(control)")
            XCTAssertGreaterThanOrEqual(frame.minX, documentView.bounds.minX)
            XCTAssertLessThanOrEqual(frame.maxX, documentView.bounds.maxX)
        }
    }

    func testLongModelAndErrorTextWrapWithinTheSettingsContent() throws {
        let model = TranscriptionModel(
            id: "a-model-identifier-that-is-long-enough-to-exercise-the-minimum-window-width",
            displayName: "A transcription model with a long descriptive display name",
            engine: .whisperKit,
            whisperKitID: "long-model",
            sizeMB: 1_620,
            languages: ["en"],
            recommended: false
        )
        let state = SettingsState(
            model: model,
            selectableModels: [model],
            preferences: AppPreferences(defaults: defaults),
            modelState: .failed(String(repeating: "Permission was denied. ", count: 12)),
            loginItemOperationError: String(repeating: "Approval is required in System Settings. ", count: 8)
        )
        let controller = SettingsWindowController(
            state: state,
            loginItemController: LoginItemController(service: FakeLoginItemService()),
            onHotkeyChoiceChanged: { _ in true }
        )
        controller.showSettings()

        let window = try XCTUnwrap(controller.window)
        window.setContentSize(window.contentMinSize)
        let contentView = try XCTUnwrap(window.contentView)
        contentView.layoutSubtreeIfNeeded()
        let scrollView = try XCTUnwrap(firstSubview(of: NSScrollView.self, in: contentView))
        let documentView = try XCTUnwrap(scrollView.documentView)
        documentView.layoutSubtreeIfNeeded()
        let labels = textLabels(in: documentView)
        let modelError = try XCTUnwrap(labels.first { $0.stringValue.hasPrefix("Model failed:") })

        XCTAssertEqual(modelError.lineBreakMode, .byWordWrapping)
        XCTAssertGreaterThan(modelError.frame.height, modelError.font?.pointSize ?? 0)
        XCTAssertLessThanOrEqual(modelError.frame.maxX, documentView.bounds.maxX)
        let expectedModelTitle = model.displayName + " (" + model.id + ", 1620 MB)"
        XCTAssertTrue(
            popUpButtons(in: documentView).contains { $0.toolTip == expectedModelTitle },
            "Expected the complete model name in a tooltip"
        )
    }

    func testShowSettingsCentersWindowInsideActiveScreenVisibleFrame() throws {
        let visibleFrame = NSRect(x: 1_200, y: 80, width: 1_000, height: 800)
        let controller = makeController(activeScreenVisibleFrame: { visibleFrame })

        controller.showSettings()

        let windowFrame = try XCTUnwrap(controller.window?.frame)
        XCTAssertEqual(windowFrame.midX, visibleFrame.midX, accuracy: 0.5)
        XCTAssertEqual(windowFrame.midY, visibleFrame.midY, accuracy: 0.5)
        XCTAssertTrue(visibleFrame.contains(windowFrame))
    }

    func testShowSettingsAgainMovesExistingWindowToNewActiveScreen() throws {
        var visibleFrame = NSRect(x: 0, y: 40, width: 1_000, height: 800)
        let controller = makeController(activeScreenVisibleFrame: { visibleFrame })
        controller.showSettings()

        visibleFrame = NSRect(x: 1_200, y: 80, width: 1_000, height: 800)
        controller.showSettings()

        let windowFrame = try XCTUnwrap(controller.window?.frame)
        XCTAssertEqual(windowFrame.midX, visibleFrame.midX, accuracy: 0.5)
        XCTAssertEqual(windowFrame.midY, visibleFrame.midY, accuracy: 0.5)
        XCTAssertTrue(visibleFrame.contains(windowFrame))
    }

    func testShowSettingsAgainPreservesActiveReplacementDraftAndSelection() throws {
        let preferences = AppPreferences(defaults: defaults)
        preferences.literalReplacements = [
            LiteralReplacement(match: "hello", replacement: "hi"),
        ]
        let state = SettingsState(model: TestModel.model, preferences: preferences)
        let controller = SettingsWindowController(
            state: state,
            loginItemController: LoginItemController(service: FakeLoginItemService()),
            onHotkeyChoiceChanged: { _ in true }
        )
        let window = try XCTUnwrap(controller.window)
        let textView = try XCTUnwrap(replacementsTextView(in: window))
        controller.showSettings()
        XCTAssertTrue(window.makeFirstResponder(textView))

        let draft = "hello => hi\nincomplete"
        textView.string = draft
        controller.textDidChange(
            Notification(name: NSText.didChangeNotification, object: textView)
        )
        let selection = NSRange(location: (draft as NSString).length - 4, length: 4)
        textView.setSelectedRange(selection)

        controller.showSettings()

        XCTAssertTrue(window.firstResponder === textView)
        XCTAssertEqual(textView.string, draft)
        XCTAssertEqual(textView.selectedRange(), selection)
    }

    func testUnrelatedStateRefreshDoesNotClobberActiveReplacementEditor() throws {
        let preferences = AppPreferences(defaults: defaults)
        preferences.literalReplacements = [
            LiteralReplacement(match: "hello", replacement: "hi"),
        ]
        let state = SettingsState(model: TestModel.model, preferences: preferences)
        let controller = SettingsWindowController(
            state: state,
            loginItemController: LoginItemController(service: FakeLoginItemService()),
            onHotkeyChoiceChanged: { _ in true }
        )
        let window = try XCTUnwrap(controller.window)
        let textView = try XCTUnwrap(replacementsTextView(in: window))
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(textView))

        let draft = "hello => hi\nincomplete"
        textView.string = draft
        controller.textDidChange(
            Notification(name: NSText.didChangeNotification, object: textView)
        )
        let selection = NSRange(location: ("hello => hi\n" as NSString).length, length: 4)
        textView.setSelectedRange(selection)

        state.setHotkeyChangeAllowed(false)

        XCTAssertEqual(textView.string, draft)
        XCTAssertEqual(textView.selectedRange(), selection)
    }

    func testShortcutButtonRecordsNextKeyChordAndUpdatesState() {
        let preferences = AppPreferences(defaults: defaults)
        let state = SettingsState(model: TestModel.model, preferences: preferences)
        var received: HotkeyChoice?
        let controller = SettingsWindowController(
            state: state,
            loginItemController: LoginItemController(service: FakeLoginItemService()),
            onHotkeyChoiceChanged: {
                received = $0
                return true
            }
        )

        controller.beginShortcutRecordingForTesting()
        XCTAssertEqual(controller.shortcutButtonTitleForTesting, "Type shortcut")
        controller.handleShortcutKeyDownForTesting(
            keyCode: 0,
            modifierFlags: [.shift, .command],
            charactersIgnoringModifiers: "a"
        )

        let choice = HotkeyChoice(
            keyCode: 0,
            requiredFlags: [.maskShift, .maskCommand],
            keyLabel: "A"
        )
        XCTAssertEqual(received, choice)
        XCTAssertEqual(state.hotkeyChoice, choice)
        XCTAssertEqual(preferences.hotkeyChoice, choice)
        XCTAssertEqual(controller.shortcutButtonTitleForTesting, "⇧⌘A")
    }

    func testEscapeCancelsShortcutRecordingWithoutChangingSavedShortcut() {
        let preferences = AppPreferences(defaults: defaults)
        preferences.hotkeyChoice = .rightOption
        let state = SettingsState(model: TestModel.model, preferences: preferences)
        var changeCount = 0
        let controller = SettingsWindowController(
            state: state,
            loginItemController: LoginItemController(service: FakeLoginItemService()),
            onHotkeyChoiceChanged: { _ in
                changeCount += 1
                return true
            }
        )

        controller.beginShortcutRecordingForTesting()
        XCTAssertTrue(state.shortcutRecordingActive)
        controller.handleShortcutKeyDownForTesting(
            keyCode: 53,
            modifierFlags: [],
            charactersIgnoringModifiers: nil
        )

        XCTAssertEqual(changeCount, 0)
        XCTAssertFalse(state.shortcutRecordingActive)
        XCTAssertEqual(preferences.hotkeyChoice, .rightOption)
        XCTAssertEqual(state.hotkeyChoice, .rightOption)
        XCTAssertEqual(
            controller.shortcutButtonTitleForTesting,
            HotkeyChoice.rightOption.displayName
        )
    }

    func testModifierOnlyShortcutRecordsAfterModifierRelease() {
        let preferences = AppPreferences(defaults: defaults)
        let state = SettingsState(model: TestModel.model, preferences: preferences)
        var received: HotkeyChoice?
        let controller = SettingsWindowController(
            state: state,
            loginItemController: LoginItemController(service: FakeLoginItemService()),
            onHotkeyChoiceChanged: {
                received = $0
                return true
            }
        )

        controller.beginShortcutRecordingForTesting()
        controller.handleShortcutFlagsChangedForTesting(
            keyCode: 54,
            modifierFlags: [.command]
        )
        XCTAssertNil(received)
        controller.handleShortcutFlagsChangedForTesting(keyCode: 54, modifierFlags: [])

        XCTAssertEqual(received, .rightCommand)
        XCTAssertEqual(
            controller.shortcutButtonTitleForTesting,
            HotkeyChoice.rightCommand.displayName
        )
    }

    func testFunctionKeyRecordsAsStandaloneWhenMacOSAddsFunctionFlag() {
        let preferences = AppPreferences(defaults: defaults)
        let state = SettingsState(model: TestModel.model, preferences: preferences)
        var received: HotkeyChoice?
        let controller = SettingsWindowController(
            state: state,
            loginItemController: LoginItemController(service: FakeLoginItemService()),
            onHotkeyChoiceChanged: {
                received = $0
                return true
            }
        )

        controller.beginShortcutRecordingForTesting()
        controller.handleShortcutKeyDownForTesting(
            keyCode: 96,
            modifierFlags: [.function],
            charactersIgnoringModifiers: nil
        )

        XCTAssertEqual(
            received,
            HotkeyChoice(keyCode: 96, requiredFlags: [], keyLabel: "F5")
        )
        XCTAssertEqual(controller.shortcutButtonTitleForTesting, "F5")
    }

    func testClosingSettingsCancelsShortcutRecording() {
        let preferences = AppPreferences(defaults: defaults)
        let state = SettingsState(model: TestModel.model, preferences: preferences)
        let controller = SettingsWindowController(
            state: state,
            loginItemController: LoginItemController(service: FakeLoginItemService()),
            onHotkeyChoiceChanged: { _ in true }
        )

        controller.beginShortcutRecordingForTesting()
        controller.window?.close()

        XCTAssertEqual(
            controller.shortcutButtonTitleForTesting,
            HotkeyChoice.defaultChoice.displayName
        )
    }

    private func interactiveControls(in view: NSView) -> [NSView] {
        var controls: [NSView] = []
        if view is NSTextView || view is NSPopUpButton || view is NSButton {
            controls.append(view)
        }
        for subview in view.subviews {
            controls.append(contentsOf: interactiveControls(in: subview))
        }
        return controls
    }

    private func textLabels(in view: NSView) -> [NSTextField] {
        var labels: [NSTextField] = []
        if let label = view as? NSTextField, !label.isEditable {
            labels.append(label)
        }
        for subview in view.subviews {
            labels.append(contentsOf: textLabels(in: subview))
        }
        return labels
    }

    private func firstSubview<View: NSView>(of type: View.Type, in view: NSView) -> View? {
        if let match = view as? View {
            return match
        }
        for subview in view.subviews {
            if let match = firstSubview(of: type, in: subview) {
                return match
            }
        }
        return nil
    }

    private func popUpButtons(in view: NSView) -> [NSPopUpButton] {
        var buttons: [NSPopUpButton] = []
        if let button = view as? NSPopUpButton {
            buttons.append(button)
        }
        for subview in view.subviews {
            buttons.append(contentsOf: popUpButtons(in: subview))
        }
        return buttons
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        var scrollViews: [NSScrollView] = []
        if let scrollView = view as? NSScrollView {
            scrollViews.append(scrollView)
        }
        for subview in view.subviews {
            scrollViews.append(contentsOf: self.scrollViews(in: subview))
        }
        return scrollViews
    }

    private func replacementsTextView(in window: NSWindow) -> NSTextView? {
        func collect(_ view: NSView) -> [NSTextView] {
            var views: [NSTextView] = []
            if let textView = view as? NSTextView {
                views.append(textView)
            }
            for subview in view.subviews {
                views.append(contentsOf: collect(subview))
            }
            return views
        }

        guard let contentView = window.contentView else { return nil }
        let textViews = collect(contentView)
        return textViews.count == 1 ? textViews[0] : nil
    }

    private func makeController(
        activeScreenVisibleFrame: @escaping () -> NSRect? = {
            NSRect(x: 0, y: 0, width: 1_440, height: 900)
        }
    ) -> SettingsWindowController {
        let preferences = AppPreferences(defaults: defaults)
        let state = SettingsState(model: TestModel.model, preferences: preferences)
        return SettingsWindowController(
            state: state,
            loginItemController: LoginItemController(service: FakeLoginItemService()),
            onHotkeyChoiceChanged: { _ in true },
            activeScreenVisibleFrame: activeScreenVisibleFrame
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

private final class FakeLoginItemService: LoginItemServiceAdapter {
    var status: LoginItemStatus = .disabled

    func register() throws {
        status = .enabled
    }

    func unregister() throws {
        status = .disabled
    }
}
