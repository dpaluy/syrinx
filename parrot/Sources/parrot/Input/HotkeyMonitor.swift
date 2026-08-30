import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public protocol HotkeyMonitoring: AnyObject {
    var choice: HotkeyChoice { get }
    func start(onEvent: @escaping (HotkeyMonitor.Event) -> Void) throws
    func stop()
}

internal protocol EventTapRegistration: AnyObject {}

internal protocol EventTapLifecycle: AnyObject {
    func makeRegistration(userInfo: UnsafeMutableRawPointer) -> (any EventTapRegistration)?
    func install(_ registration: any EventTapRegistration)
    func uninstall(_ registration: any EventTapRegistration)
    func enable(_ registration: any EventTapRegistration)
    func disable(_ registration: any EventTapRegistration)
    func isEnabled(_ registration: any EventTapRegistration) -> Bool
}

/// Watches a single modifier key and emits press/release edges.
/// Requires Accessibility permission. If the tap fails to register, callers
/// will see an error from `start()`.
public final class HotkeyMonitor: HotkeyMonitoring {
    public enum Event: Equatable { case pressed, released, monitoringFailed }
    public enum HotkeyError: Error { case tapCreateFailed }

    public private(set) var choice: HotkeyChoice
    private let debug: Bool
    private let eventTapLifecycle: any EventTapLifecycle
    private let isAccessibilityTrusted: () -> Bool
    private var onEvent: ((Event) -> Void)?
    private var registration: (any EventTapRegistration)?
    private var isPressed = false

    public convenience init(choice: HotkeyChoice = .fnOrGlobe, debug: Bool = false) {
        self.init(
            choice: choice,
            debug: debug,
            eventTapLifecycle: SystemEventTapLifecycle(),
            isAccessibilityTrusted: {
                let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                return AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
            }
        )
    }

    internal init(
        choice: HotkeyChoice,
        debug: Bool,
        eventTapLifecycle: any EventTapLifecycle,
        isAccessibilityTrusted: @escaping () -> Bool
    ) {
        self.choice = choice
        self.debug = debug
        self.eventTapLifecycle = eventTapLifecycle
        self.isAccessibilityTrusted = isAccessibilityTrusted
    }

    /// Compatibility initializer for callers that used the original Fn mask.
    public convenience init(mask: CGEventFlags, debug: Bool = false) {
        let choice: HotkeyChoice = mask.contains(.maskCommand)
            ? .rightCommand
            : mask.contains(.maskAlternate) ? .rightOption : .fnOrGlobe
        self.init(choice: choice, debug: debug)
    }

    /// Mask of the selected modifier, retained for compatibility with older callers.
    public var mask: CGEventFlags { choice.requiredFlags }

    public func start(onEvent: @escaping (Event) -> Void) throws {
        stop()
        self.onEvent = onEvent

        guard isAccessibilityTrusted() else {
            FileHandle.standardError.write(Data(
                "accessibility not granted  -  system prompt opened. Grant access, then quit and relaunch parrot.\n".utf8
            ))
            throw HotkeyError.tapCreateFailed
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let registration = eventTapLifecycle.makeRegistration(userInfo: userInfo) else {
            throw HotkeyError.tapCreateFailed
        }

        self.registration = registration
        eventTapLifecycle.install(registration)
        eventTapLifecycle.enable(registration)
    }

    public func stop() {
        if let registration {
            remove(registration)
        }
        registration = nil
        onEvent = nil
        isPressed = false
    }

    internal func handle(type: CGEventType, event: CGEvent) {
        if debug {
            let flags = event.flags
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            FileHandle.standardError.write(
                Data(
                    "  [debug] type=\(type.rawValue) keycode=\(keycode) flags=\(String(flags.rawValue, radix: 16))\n"
                        .utf8
                ))
        }
        guard type == .flagsChanged else { return }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Int64(choice.keyCode) else { return }
        if isPressed {
            isPressed = false
            onEvent?(.released)
        } else {
            guard event.flags.contains(choice.requiredFlags) else { return }
            isPressed = true
            onEvent?(.pressed)
        }
    }

    internal func handleTapDisabled(type: CGEventType) {
        guard type == .tapDisabledByTimeout || type == .tapDisabledByUserInput else { return }

        if isPressed {
            isPressed = false
            onEvent?(.released)
        }

        guard let registration else {
            onEvent?(.monitoringFailed)
            return
        }

        eventTapLifecycle.enable(registration)
        if eventTapLifecycle.isEnabled(registration) {
            return
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let replacement = eventTapLifecycle.makeRegistration(userInfo: userInfo) else {
            remove(registration)
            self.registration = nil
            onEvent?(.monitoringFailed)
            return
        }

        remove(registration)
        self.registration = replacement
        eventTapLifecycle.install(replacement)
        eventTapLifecycle.enable(replacement)

        guard eventTapLifecycle.isEnabled(replacement) else {
            remove(replacement)
            self.registration = nil
            onEvent?(.monitoringFailed)
            return
        }
    }

    internal func setTestingHandler(_ onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
    }

    private func remove(_ registration: any EventTapRegistration) {
        eventTapLifecycle.disable(registration)
        eventTapLifecycle.uninstall(registration)
    }
}

private final class SystemEventTapRegistration: EventTapRegistration {
    let tap: CFMachPort
    let source: CFRunLoopSource

    init(tap: CFMachPort, source: CFRunLoopSource) {
        self.tap = tap
        self.source = source
    }
}

private final class SystemEventTapLifecycle: EventTapLifecycle {
    func makeRegistration(userInfo: UnsafeMutableRawPointer) -> (any EventTapRegistration)? {
        let eventMask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: eventMask,
                callback: hotkeyCallback,
                userInfo: userInfo
            ),
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        else {
            return nil
        }

        return SystemEventTapRegistration(tap: tap, source: source)
    }

    func install(_ registration: any EventTapRegistration) {
        let registration = systemRegistration(registration)
        CFRunLoopAddSource(CFRunLoopGetMain(), registration.source, .commonModes)
    }

    func uninstall(_ registration: any EventTapRegistration) {
        let registration = systemRegistration(registration)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), registration.source, .commonModes)
    }

    func enable(_ registration: any EventTapRegistration) {
        let registration = systemRegistration(registration)
        CGEvent.tapEnable(tap: registration.tap, enable: true)
    }

    func disable(_ registration: any EventTapRegistration) {
        let registration = systemRegistration(registration)
        CGEvent.tapEnable(tap: registration.tap, enable: false)
    }

    func isEnabled(_ registration: any EventTapRegistration) -> Bool {
        let registration = systemRegistration(registration)
        return CGEvent.tapIsEnabled(tap: registration.tap)
    }

    private func systemRegistration(
        _ registration: any EventTapRegistration
    ) -> SystemEventTapRegistration {
        registration as! SystemEventTapRegistration
    }
}

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        DispatchQueue.main.async {
            monitor.handleTapDisabled(type: type)
        }
        return Unmanaged.passUnretained(event)
    }

    let copy = event.copy()
    DispatchQueue.main.async {
        if let copy {
            monitor.handle(type: type, event: copy)
        }
    }
    return Unmanaged.passUnretained(event)
}
