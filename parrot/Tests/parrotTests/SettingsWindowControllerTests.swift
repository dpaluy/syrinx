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
        XCTAssertEqual(controls.count, 7)
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
