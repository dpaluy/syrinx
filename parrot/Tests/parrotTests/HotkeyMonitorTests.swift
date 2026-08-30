import XCTest
import CoreGraphics
@testable import SyrinxClient

final class HotkeyMonitorTests: XCTestCase {
    func testMonitorEmitsOnePressAndReleaseForEachSupportedChoice() throws {
        for choice in HotkeyChoice.allCases {
            let monitor = HotkeyMonitor(choice: choice)
            var events: [HotkeyMonitor.Event] = []
            try monitor.handleForTesting { events.append($0) }

            let pressed = event(keyCode: choice.keyCode, flags: choice.requiredFlags)
            let released = event(keyCode: choice.keyCode, flags: [])
            let repeatedRelease = event(keyCode: choice.keyCode, flags: [])
            monitor.handle(type: .flagsChanged, event: pressed)
            monitor.handle(type: .flagsChanged, event: released)
            monitor.handle(type: .flagsChanged, event: repeatedRelease)

            XCTAssertEqual(events.count, 2, choice.displayName)
            if events.count == 2 {
                XCTAssertEqual(events[0], .pressed, choice.displayName)
                XCTAssertEqual(events[1], .released, choice.displayName)
            }
        }
    }

    func testMonitorIgnoresOtherKeyCodesAndEventTypes() throws {
        let monitor = HotkeyMonitor(choice: .rightCommand)
        var events: [HotkeyMonitor.Event] = []
        try monitor.handleForTesting { events.append($0) }

        monitor.handle(
            type: .flagsChanged,
            event: event(keyCode: HotkeyChoice.rightOption.keyCode, flags: .maskAlternate)
        )
        monitor.handle(
            type: .keyDown,
            event: event(keyCode: HotkeyChoice.rightCommand.keyCode, flags: .maskCommand)
        )
        XCTAssertTrue(events.isEmpty)
    }

    func testMonitorEmitsCancelForEscapeKeyDownOnly() throws {
        let monitor = HotkeyMonitor(choice: .fnOrGlobe)
        var events: [HotkeyMonitor.Event] = []
        try monitor.handleForTesting { events.append($0) }

        monitor.handle(type: .keyDown, event: event(keyCode: 53, flags: []))
        monitor.handle(type: .keyUp, event: event(keyCode: 53, flags: []))

        XCTAssertEqual(events, [.cancel])
    }

    func testRightCommandReleaseUsesSelectedPhysicalKeyWithLeftCommandHeld() throws {
        let monitor = HotkeyMonitor(choice: .rightCommand)
        var events: [HotkeyMonitor.Event] = []
        try monitor.handleForTesting { events.append($0) }

        monitor.handle(
            type: .flagsChanged,
            event: event(keyCode: HotkeyChoice.rightCommand.keyCode, flags: .maskCommand)
        )
        monitor.handle(
            type: .flagsChanged,
            event: event(keyCode: 55, flags: .maskCommand)
        )
        monitor.handle(
            type: .flagsChanged,
            event: event(keyCode: HotkeyChoice.rightCommand.keyCode, flags: .maskCommand)
        )
        monitor.handle(
            type: .flagsChanged,
            event: event(keyCode: 55, flags: [])
        )

        XCTAssertEqual(events, [.pressed, .released])
    }

    func testRightOptionReleaseUsesSelectedPhysicalKeyWithLeftOptionHeld() throws {
        let monitor = HotkeyMonitor(choice: .rightOption)
        var events: [HotkeyMonitor.Event] = []
        try monitor.handleForTesting { events.append($0) }

        monitor.handle(
            type: .flagsChanged,
            event: event(keyCode: HotkeyChoice.rightOption.keyCode, flags: .maskAlternate)
        )
        monitor.handle(
            type: .flagsChanged,
            event: event(keyCode: 58, flags: .maskAlternate)
        )
        monitor.handle(
            type: .flagsChanged,
            event: event(keyCode: HotkeyChoice.rightOption.keyCode, flags: .maskAlternate)
        )
        monitor.handle(
            type: .flagsChanged,
            event: event(keyCode: 58, flags: [])
        )

        XCTAssertEqual(events, [.pressed, .released])
    }

    func testReleaseWithoutSelectedPressDoesNotEmitAnEdge() throws {
        let monitor = HotkeyMonitor(choice: .rightCommand)
        var events: [HotkeyMonitor.Event] = []
        try monitor.handleForTesting { events.append($0) }

        monitor.handle(
            type: .flagsChanged,
            event: event(keyCode: HotkeyChoice.rightCommand.keyCode, flags: [])
        )

        XCTAssertTrue(events.isEmpty)
    }

    private func event(keyCode: CGKeyCode, flags: CGEventFlags) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)!
        event.flags = flags
        return event
    }
}

private extension HotkeyMonitor {
    func handleForTesting(_ onEvent: @escaping (Event) -> Void) throws {
        setTestingHandler(onEvent)
    }
}
