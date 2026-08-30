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

    func testDisabledTapTypesReleasePressedStateAndReenableExistingTap() throws {
        for type in [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput] {
            let lifecycle = FakeEventTapLifecycle(enableResults: [true, true])
            let monitor = makeMonitor(lifecycle: lifecycle)
            var events: [HotkeyMonitor.Event] = []
            try monitor.start { events.append($0) }

            monitor.handle(
                type: .flagsChanged,
                event: event(keyCode: monitor.choice.keyCode, flags: monitor.choice.requiredFlags)
            )
            monitor.handleTapDisabled(type: type)
            monitor.handle(
                type: .flagsChanged,
                event: event(keyCode: monitor.choice.keyCode, flags: monitor.choice.requiredFlags)
            )

            XCTAssertEqual(events, [.pressed, .released, .pressed])
            XCTAssertEqual(lifecycle.registrationCount, 1)
            XCTAssertEqual(lifecycle.installedCount, 1)
            XCTAssertEqual(lifecycle.maximumInstalledCount, 1)
            monitor.stop()
        }
    }

    func testFailedReenableRecreatesTapWithoutDuplicateRunLoopSources() throws {
        let lifecycle = FakeEventTapLifecycle(
            enableResults: [true, false, true, false, true]
        )
        let monitor = makeMonitor(lifecycle: lifecycle)
        var events: [HotkeyMonitor.Event] = []
        try monitor.start { events.append($0) }

        monitor.handleTapDisabled(type: .tapDisabledByTimeout)
        monitor.handleTapDisabled(type: .tapDisabledByUserInput)

        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(lifecycle.registrationCount, 3)
        XCTAssertEqual(lifecycle.installCount, 3)
        XCTAssertEqual(lifecycle.uninstallCount, 2)
        XCTAssertEqual(lifecycle.installedCount, 1)
        XCTAssertEqual(lifecycle.maximumInstalledCount, 1)
    }

    func testFailedTapRecreationReportsMonitoringFailureAndRemovesSource() throws {
        let lifecycle = FakeEventTapLifecycle(
            creationResults: [true, false],
            enableResults: [true, false]
        )
        let monitor = makeMonitor(lifecycle: lifecycle)
        var events: [HotkeyMonitor.Event] = []
        try monitor.start { events.append($0) }

        monitor.handleTapDisabled(type: .tapDisabledByTimeout)

        XCTAssertEqual(events, [.monitoringFailed])
        XCTAssertEqual(lifecycle.installedCount, 0)
        XCTAssertEqual(lifecycle.maximumInstalledCount, 1)
    }

    private func makeMonitor(lifecycle: FakeEventTapLifecycle) -> HotkeyMonitor {
        HotkeyMonitor(
            choice: .fnOrGlobe,
            debug: false,
            eventTapLifecycle: lifecycle,
            isAccessibilityTrusted: { true }
        )
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

private final class FakeEventTapRegistration: EventTapRegistration {
    var isEnabled = false
}

private final class FakeEventTapLifecycle: EventTapLifecycle {
    private var creationResults: [Bool]
    private var enableResults: [Bool]
    private var installed: Set<ObjectIdentifier> = []

    private(set) var registrationCount = 0
    private(set) var installCount = 0
    private(set) var uninstallCount = 0
    private(set) var maximumInstalledCount = 0

    var installedCount: Int { installed.count }

    init(
        creationResults: [Bool] = [],
        enableResults: [Bool]
    ) {
        self.creationResults = creationResults
        self.enableResults = enableResults
    }

    func makeRegistration(userInfo: UnsafeMutableRawPointer) -> (any EventTapRegistration)? {
        let shouldCreate = creationResults.isEmpty ? true : creationResults.removeFirst()
        guard shouldCreate else { return nil }
        registrationCount += 1
        return FakeEventTapRegistration()
    }

    func install(_ registration: any EventTapRegistration) {
        installCount += 1
        installed.insert(ObjectIdentifier(registration))
        maximumInstalledCount = max(maximumInstalledCount, installed.count)
    }

    func uninstall(_ registration: any EventTapRegistration) {
        uninstallCount += 1
        installed.remove(ObjectIdentifier(registration))
    }

    func enable(_ registration: any EventTapRegistration) {
        let registration = registration as! FakeEventTapRegistration
        registration.isEnabled = enableResults.removeFirst()
    }

    func disable(_ registration: any EventTapRegistration) {
        let registration = registration as! FakeEventTapRegistration
        registration.isEnabled = false
    }

    func isEnabled(_ registration: any EventTapRegistration) -> Bool {
        let registration = registration as! FakeEventTapRegistration
        return registration.isEnabled
    }
}
