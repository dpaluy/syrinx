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

public enum TextOutputMode: String, CaseIterable, Codable, Sendable {
    case directTyping
    case clipboardPaste

    public var displayName: String {
        switch self {
        case .directTyping:
            return "Direct typing"
        case .clipboardPaste:
            return "Clipboard paste"
        }
    }
}

enum LiteralReplacementSettingsText {
    private static let separator = " => "

    static func encode(_ replacements: [LiteralReplacement]) -> String {
        replacements
            .map { "\($0.match)\(separator)\($0.replacement)" }
            .joined(separator: "\n")
    }

    static func decode(_ text: String) -> [LiteralReplacement] {
        text.components(separatedBy: .newlines).compactMap { line in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
                  let separator = line.range(of: Self.separator)
            else {
                return nil
            }
            let match = String(line[..<separator.lowerBound])
            let replacement = String(line[separator.upperBound...])
            guard !match.isEmpty else {
                return nil
            }
            return LiteralReplacement(match: match, replacement: replacement)
        }
    }
}

/// User preferences that affect the packaged Syrinx app at runtime.
public final class AppPreferences {
    public enum Keys {
        public static let addTrailingSpace = "Syrinx.addTrailingSpace"
        public static let hotkeyChoice = "Syrinx.hotkeyChoice"
        public static let textOutputMode = "Syrinx.textOutputMode"
        public static let selectedModelID = "Syrinx.selectedModelID"
        public static let literalReplacements = "Syrinx.literalReplacements"
        public static let spokenPunctuationEnabled = "Syrinx.spokenPunctuationEnabled"
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

    public var literalReplacements: [LiteralReplacement] {
        get {
            guard let data = defaults.data(forKey: Keys.literalReplacements),
                  let replacements = try? JSONDecoder().decode(
                      [LiteralReplacement].self,
                      from: data
                  )
            else {
                return []
            }
            return replacements
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Keys.literalReplacements)
        }
    }

    public var spokenPunctuationEnabled: Bool {
        get {
            guard let value = defaults.object(forKey: Keys.spokenPunctuationEnabled) as? Bool else {
                return false
            }
            return value
        }
        set {
            defaults.set(newValue, forKey: Keys.spokenPunctuationEnabled)
        }
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

    public var textOutputMode: TextOutputMode {
        get {
            guard let rawValue = defaults.string(forKey: Keys.textOutputMode),
                  let mode = TextOutputMode(rawValue: rawValue)
            else {
                return .directTyping
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.textOutputMode)
        }
    }

    /// Nil preserves the recommended model for existing users.
    public var selectedModelID: String? {
        get { defaults.string(forKey: Keys.selectedModelID) }
        set { defaults.set(newValue, forKey: Keys.selectedModelID) }
    }
}
