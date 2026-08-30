import CoreGraphics
import Foundation

/// A user-recorded hold-to-record shortcut.
public struct HotkeyChoice: Codable, Hashable, Sendable {
    public let keyCode: CGKeyCode
    public let keyLabel: String
    public let isModifierOnly: Bool
    private let requiredFlagsRawValue: UInt64

    public init(
        keyCode: CGKeyCode,
        requiredFlags: CGEventFlags,
        keyLabel: String,
        isModifierOnly: Bool = false
    ) {
        self.keyCode = keyCode
        self.keyLabel = keyLabel
        self.isModifierOnly = isModifierOnly
        self.requiredFlagsRawValue = Self.normalized(requiredFlags).rawValue
    }

    public var requiredFlags: CGEventFlags {
        Self.normalized(CGEventFlags(rawValue: requiredFlagsRawValue))
    }

    public var displayName: String {
        if isModifierOnly {
            return keyLabel
        }
        return Self.modifierSymbols(for: requiredFlags) + keyLabel
    }

    var isFunctionKey: Bool {
        guard keyLabel.first == "F",
              let number = Int(keyLabel.dropFirst())
        else { return false }
        return (1...35).contains(number)
    }

    func matches(_ eventFlags: CGEventFlags) -> Bool {
        var eventFlags = Self.normalized(eventFlags)
        if isFunctionKey, !requiredFlags.contains(.maskSecondaryFn) {
            eventFlags.remove(.maskSecondaryFn)
        }
        return eventFlags == requiredFlags
    }

    public static let fnOrGlobe = HotkeyChoice(
        keyCode: 63,
        requiredFlags: .maskSecondaryFn,
        keyLabel: "fn",
        isModifierOnly: true
    )
    public static let rightCommand = HotkeyChoice(
        keyCode: 54,
        requiredFlags: .maskCommand,
        keyLabel: "Right ⌘",
        isModifierOnly: true
    )
    public static let rightOption = HotkeyChoice(
        keyCode: 61,
        requiredFlags: .maskAlternate,
        keyLabel: "Right ⌥",
        isModifierOnly: true
    )
    public static let defaultChoice: HotkeyChoice = .fnOrGlobe

    /// Retained for callers that enumerate the original built-in choices.
    public static let allCases: [HotkeyChoice] = [.fnOrGlobe, .rightCommand, .rightOption]

    static func normalized(_ flags: CGEventFlags) -> CGEventFlags {
        flags.intersection([
            .maskControl,
            .maskAlternate,
            .maskShift,
            .maskCommand,
            .maskSecondaryFn,
            .maskAlphaShift,
        ])
    }

    static func legacyChoice(rawValue: String) -> HotkeyChoice? {
        switch rawValue {
        case "fnOrGlobe": return .fnOrGlobe
        case "rightCommand": return .rightCommand
        case "rightOption": return .rightOption
        default: return nil
        }
    }

    private static func modifierSymbols(for flags: CGEventFlags) -> String {
        var result = ""
        if flags.contains(.maskControl) { result += "⌃" }
        if flags.contains(.maskAlternate) { result += "⌥" }
        if flags.contains(.maskShift) { result += "⇧" }
        if flags.contains(.maskCommand) { result += "⌘" }
        if flags.contains(.maskSecondaryFn) { result += "fn " }
        if flags.contains(.maskAlphaShift) { result += "⇪" }
        return result
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
    private static let obsoleteAddTrailingSpaceKey = "Syrinx.addTrailingSpace"

    public enum Keys {
        public static let hotkeyChoice = "Syrinx.hotkeyChoice"
        public static let textOutputMode = "Syrinx.textOutputMode"
        public static let selectedModelID = "Syrinx.selectedModelID"
        public static let literalReplacements = "Syrinx.literalReplacements"
        public static let spokenPunctuationEnabled = "Syrinx.spokenPunctuationEnabled"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.removeObject(forKey: Self.obsoleteAddTrailingSpaceKey)
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
            if let data = defaults.data(forKey: Keys.hotkeyChoice),
               let choice = try? JSONDecoder().decode(HotkeyChoice.self, from: data) {
                return choice
            }
            if let rawValue = defaults.string(forKey: Keys.hotkeyChoice),
               let choice = HotkeyChoice.legacyChoice(rawValue: rawValue) {
                return choice
            }
            return .defaultChoice
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Keys.hotkeyChoice)
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
