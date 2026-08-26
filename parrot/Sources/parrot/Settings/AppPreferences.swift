import CoreGraphics
import Foundation

/// The supported hold-to-record controls.
public enum HotkeyChoice: String, CaseIterable, Codable, Sendable {
    case fnOrGlobe = "fnOrGlobe"
    case rightCommand = "rightCommand"
    case rightOption = "rightOption"

    public static let defaultChoice: HotkeyChoice = .fnOrGlobe

    public var displayName: String {
        switch self {
        case .fnOrGlobe:
            return "Fn or Globe"
        case .rightCommand:
            return "Right Command"
        case .rightOption:
            return "Right Option"
        }
    }

    /// The physical key code emitted by macOS for this modifier key.
    public var keyCode: CGKeyCode {
        switch self {
        case .fnOrGlobe:
            return 63
        case .rightCommand:
            return 54
        case .rightOption:
            return 61
        }
    }

    /// The modifier flag that must be present for this key to be held.
    public var requiredFlags: CGEventFlags {
        switch self {
        case .fnOrGlobe:
            return .maskSecondaryFn
        case .rightCommand:
            return .maskCommand
        case .rightOption:
            return .maskAlternate
        }
    }
}

/// User preferences that affect the packaged Syrinx app at runtime.
public final class AppPreferences {
    public enum Keys {
        public static let addTrailingSpace = "Syrinx.addTrailingSpace"
        public static let hotkeyChoice = "Syrinx.hotkeyChoice"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var addTrailingSpace: Bool {
        get {
            guard let value = defaults.object(forKey: Keys.addTrailingSpace) as? Bool else {
                return true
            }
            return value
        }
        set {
            defaults.set(newValue, forKey: Keys.addTrailingSpace)
        }
    }

    /// Alias that keeps the setting name clear at call sites.
    public var trailingSpace: Bool {
        get { addTrailingSpace }
        set { addTrailingSpace = newValue }
    }

    public var hotkeyChoice: HotkeyChoice {
        get {
            guard let rawValue = defaults.string(forKey: Keys.hotkeyChoice),
                  let choice = HotkeyChoice(rawValue: rawValue)
            else {
                return .defaultChoice
            }
            return choice
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.hotkeyChoice)
        }
    }
}
