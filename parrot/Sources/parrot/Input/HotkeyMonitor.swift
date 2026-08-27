import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public protocol HotkeyMonitoring: AnyObject {
    var choice: HotkeyChoice { get }
    func start(onEvent: @escaping (HotkeyMonitor.Event) -> Void) throws
    func stop()
}

/// Watches a single modifier key and emits press/release edges.
/// Requires Accessibility permission. If the tap fails to register, callers
/// will see an error from `start()`.
public final class HotkeyMonitor: HotkeyMonitoring {
    public enum Event: Equatable { case pressed, released }
    public enum HotkeyError: Error { case tapCreateFailed }

    public private(set) var choice: HotkeyChoice
    private let debug: Bool
    private var onEvent: ((Event) -> Void)?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false

    public init(choice: HotkeyChoice = .fnOrGlobe, debug: Bool = false) {
        self.choice = choice
        self.debug = debug
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

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        if !trusted {
            FileHandle.standardError.write(Data(
                "accessibility not granted  -  system prompt opened. Grant access, then quit and relaunch parrot.\n".utf8
            ))
            throw HotkeyError.tapCreateFailed
        }

        let eventMask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        // .cgSessionEventTap is the right level for an accessibility-granted
        // user process (.cghidEventTap requires root).
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: eventMask,
                callback: hotkeyCallback,
                userInfo: userInfo
            )
        else {
            throw HotkeyError.tapCreateFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
    }

    public func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
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

    internal func setTestingHandler(_ onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
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
        // System disabled our tap; we'll need to re-enable. For now just no-op
        // and let the user restart parrot.
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
