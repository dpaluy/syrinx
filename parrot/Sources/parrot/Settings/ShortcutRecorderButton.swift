import AppKit
import CoreGraphics

@MainActor
final class ShortcutRecorderButton: NSButton {
    var onShortcutRecorded: ((HotkeyChoice) -> Bool)?
    var onRecordingChanged: ((Bool) -> Void)?

    private(set) var shortcut: HotkeyChoice = .defaultChoice
    private(set) var isRecordingShortcut = false
    private var eventMonitor: Any?
    private var recordingState = ShortcutRecordingState()

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(toggleRecording)
        setShortcut(.defaultChoice)
    }

    required init?(coder: NSCoder) {
        fatalError("ShortcutRecorderButton does not support storyboards")
    }

    func setShortcut(_ shortcut: HotkeyChoice) {
        self.shortcut = shortcut
        if !isRecordingShortcut {
            title = shortcut.displayName
        }
    }

    func beginRecording() {
        guard isEnabled else { return }
        stopEventMonitor()
        recordingState = ShortcutRecordingState()
        isRecordingShortcut = true
        title = "Type shortcut"
        onRecordingChanged?(true)
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged]
        ) { [weak self] event in
            guard let self, self.isRecordingShortcut else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func handleKeyDown(
        keyCode: CGKeyCode,
        modifierFlags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?
    ) {
        guard isRecordingShortcut else { return }
        apply(recordingState.keyDown(
            keyCode: keyCode,
            flags: Self.cgFlags(from: modifierFlags),
            charactersIgnoringModifiers: charactersIgnoringModifiers
        ))
    }

    func handleFlagsChanged(
        keyCode: CGKeyCode,
        modifierFlags: NSEvent.ModifierFlags
    ) {
        guard isRecordingShortcut else { return }
        apply(recordingState.flagsChanged(
            keyCode: keyCode,
            flags: Self.cgFlags(from: modifierFlags)
        ))
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            cancelRecording()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func toggleRecording() {
        if isRecordingShortcut {
            cancelRecording()
        } else {
            beginRecording()
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyDown:
            handleKeyDown(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers
            )
        case .flagsChanged:
            handleFlagsChanged(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags
            )
        default:
            return false
        }
        return true
    }

    private func apply(_ result: ShortcutRecordingResult) {
        switch result {
        case .waiting(let display):
            title = display
        case .cancelled:
            cancelRecording()
        case .recorded(let choice):
            finishRecording()
            guard onShortcutRecorded?(choice) == true else {
                title = shortcut.displayName
                return
            }
            setShortcut(choice)
        case .ignored:
            return
        }
    }

    func cancelRecording() {
        guard isRecordingShortcut else { return }
        finishRecording()
        title = shortcut.displayName
    }

    private func finishRecording() {
        isRecordingShortcut = false
        stopEventMonitor()
        onRecordingChanged?(false)
    }

    private func stopEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
    }

    private static func cgFlags(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var result: CGEventFlags = []
        if flags.contains(.control) { result.insert(.maskControl) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        if flags.contains(.command) { result.insert(.maskCommand) }
        if flags.contains(.function) { result.insert(.maskSecondaryFn) }
        if flags.contains(.capsLock) { result.insert(.maskAlphaShift) }
        return result
    }
}

private enum ShortcutRecordingResult {
    case ignored
    case waiting(String)
    case cancelled
    case recorded(HotkeyChoice)
}

private struct ShortcutRecordingState {
    private var pressedModifierKeyCodes: Set<CGKeyCode> = []
    private var accumulatedFlags: CGEventFlags = []
    private var primaryModifierKeyCode: CGKeyCode?

    mutating func keyDown(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        charactersIgnoringModifiers: String?
    ) -> ShortcutRecordingResult {
        if keyCode == 53 {
            return .cancelled
        }
        guard let label = ShortcutKeyLabel.label(
            keyCode: keyCode,
            charactersIgnoringModifiers: charactersIgnoringModifiers
        ) else {
            return .ignored
        }
        var requiredFlags = HotkeyChoice.normalized(flags)
        if ShortcutKeyLabel.isFunctionKey(label) {
            requiredFlags.remove(.maskSecondaryFn)
        }
        return .recorded(HotkeyChoice(
            keyCode: keyCode,
            requiredFlags: requiredFlags,
            keyLabel: label
        ))
    }

    mutating func flagsChanged(
        keyCode: CGKeyCode,
        flags: CGEventFlags
    ) -> ShortcutRecordingResult {
        guard let keyFlag = ShortcutKeyLabel.modifierFlag(for: keyCode) else {
            return .ignored
        }

        if pressedModifierKeyCodes.remove(keyCode) != nil {
            guard pressedModifierKeyCodes.isEmpty,
                  let primaryModifierKeyCode
            else {
                return .waiting(ShortcutKeyLabel.modifierNotation(for: accumulatedFlags))
            }
            return .recorded(HotkeyChoice(
                keyCode: primaryModifierKeyCode,
                requiredFlags: accumulatedFlags,
                keyLabel: ShortcutKeyLabel.modifierOnlyLabel(
                    keyCode: primaryModifierKeyCode,
                    flags: accumulatedFlags
                ),
                isModifierOnly: true
            ))
        }

        pressedModifierKeyCodes.insert(keyCode)
        primaryModifierKeyCode = keyCode
        accumulatedFlags.formUnion(HotkeyChoice.normalized(flags))
        accumulatedFlags.insert(keyFlag)
        return .waiting(ShortcutKeyLabel.modifierNotation(for: accumulatedFlags))
    }
}

private enum ShortcutKeyLabel {
    private static let fixedLabels: [CGKeyCode: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 71: "Clear",
        76: "⌤", 114: "Help", 115: "↖", 116: "⇞", 117: "⌦",
        119: "↘", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5",
        97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    static func label(
        keyCode: CGKeyCode,
        charactersIgnoringModifiers: String?
    ) -> String? {
        if let fixed = fixedLabels[keyCode] {
            return fixed
        }
        guard let charactersIgnoringModifiers,
              !charactersIgnoringModifiers.isEmpty
        else {
            return nil
        }
        if charactersIgnoringModifiers.unicodeScalars.count == 1,
           let scalar = charactersIgnoringModifiers.unicodeScalars.first,
           (0xF704...0xF726).contains(scalar.value) {
            return "F\(scalar.value - 0xF704 + 1)"
        }
        return charactersIgnoringModifiers.uppercased()
    }

    static func isFunctionKey(_ label: String) -> Bool {
        guard label.first == "F",
              let number = Int(label.dropFirst())
        else { return false }
        return (1...35).contains(number)
    }

    static func modifierFlag(for keyCode: CGKeyCode) -> CGEventFlags? {
        switch keyCode {
        case 54, 55: return .maskCommand
        case 56, 60: return .maskShift
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        case 63: return .maskSecondaryFn
        case 57: return .maskAlphaShift
        default: return nil
        }
    }

    static func modifierOnlyLabel(keyCode: CGKeyCode, flags: CGEventFlags) -> String {
        if flags == modifierFlag(for: keyCode) {
            switch keyCode {
            case 54: return "Right ⌘"
            case 55: return "Left ⌘"
            case 56: return "Left ⇧"
            case 60: return "Right ⇧"
            case 58: return "Left ⌥"
            case 61: return "Right ⌥"
            case 59: return "Left ⌃"
            case 62: return "Right ⌃"
            case 63: return "fn"
            case 57: return "⇪"
            default: break
            }
        }
        return modifierNotation(for: flags)
    }

    static func modifierNotation(for flags: CGEventFlags) -> String {
        var result = ""
        if flags.contains(.maskControl) { result += "⌃" }
        if flags.contains(.maskAlternate) { result += "⌥" }
        if flags.contains(.maskShift) { result += "⇧" }
        if flags.contains(.maskCommand) { result += "⌘" }
        if flags.contains(.maskSecondaryFn) { result += "fn" }
        if flags.contains(.maskAlphaShift) { result += "⇪" }
        return result
    }
}
