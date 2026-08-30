import Foundation

/// Decides whether captured audio is long enough to transcribe.
public enum UtteranceAcceptancePolicy {
    public static let minimumSampleCount = 4_800

    public static func accepts(sampleCount: Int) -> Bool {
        sampleCount >= minimumSampleCount
    }
}

public struct LiteralReplacement: Codable, Equatable, Sendable {
    public let match: String
    public let replacement: String

    public init(match: String, replacement: String) {
        self.match = match
        self.replacement = replacement
    }
}

/// Formats successful transcription output before it reaches the text injector.
public enum TextOutputPolicy {
    private enum TransformationError: Error {
        case emptyReplacementMatch
    }

    private static let spokenPunctuation: [(phrase: String, symbol: String)] = [
        ("question mark", "?"),
        ("exclamation mark", "!"),
        ("exclamation point", "!"),
        ("open parenthesis", "("),
        ("close parenthesis", ")"),
        ("open paren", "("),
        ("close paren", ")"),
        ("open bracket", "["),
        ("close bracket", "]"),
        ("new line", "\n"),
        ("period", "."),
        ("comma", ","),
        ("colon", ":"),
        ("semicolon", ";"),
        ("dash", "-"),
        ("slash", "/"),
    ]
    /// Removes common non-speech tokens and normalizes whitespace.
    public static func sanitize(_ text: String) -> String {
        let patterns = [
            #"\[[^\]]*\]"#,        // [BLANK_AUDIO], [MUSIC], [Applause]
            #"\([^)]*\)"#,          // (silence), (music playing)
            #"<\|[^|]*\|>"#,        // <|nospeech|>, <|endoftext|>
            #"\*[^*]*\*"#,          // *background noise*
        ]
        var output = text
        for pattern in patterns {
            output = output.replacingOccurrences(
                of: pattern,
                with: " ",
                options: .regularExpression
            )
        }
        output = output.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns nil when the processed transcript is empty or punctuation-only.
    public static func output(
        for text: String,
        literalReplacements: [LiteralReplacement] = [],
        spokenPunctuationEnabled: Bool = false
    ) -> String? {
        let sanitized = sanitize(text)
        let transformed: String
        do {
            transformed = try transform(
                sanitized,
                literalReplacements: literalReplacements,
                spokenPunctuationEnabled: spokenPunctuationEnabled
            )
        } catch {
            transformed = sanitized
        }

        let ignoredCharacters = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        guard transformed.unicodeScalars.contains(where: { !ignoredCharacters.contains($0) }) else {
            return nil
        }
        return transformed
    }

    private static func transform(
        _ text: String,
        literalReplacements: [LiteralReplacement],
        spokenPunctuationEnabled: Bool
    ) throws -> String {
        var transformed = text
        for replacement in literalReplacements {
            guard !replacement.match.isEmpty else {
                throw TransformationError.emptyReplacementMatch
            }
            transformed = transformed.replacingOccurrences(
                of: replacement.match,
                with: replacement.replacement
            )
        }

        if spokenPunctuationEnabled {
            transformed = try applySpokenPunctuation(to: transformed)
        }
        return transformed
    }

    private static func applySpokenPunctuation(to text: String) throws -> String {
        var transformed = text
        for entry in spokenPunctuation {
            let phrase = NSRegularExpression.escapedPattern(for: entry.phrase)
            let expression = try NSRegularExpression(
                pattern: "(?i)\\b\(phrase)\\b"
            )
            let range = NSRange(transformed.startIndex..<transformed.endIndex, in: transformed)
            transformed = expression.stringByReplacingMatches(
                in: transformed,
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: entry.symbol)
            )
        }
        return cleanPunctuationSpacing(transformed)
    }

    private static func cleanPunctuationSpacing(_ text: String) -> String {
        var transformed = text
        for punctuation in [".", ",", "?", "!", ":", ";", ")", "]"] {
            transformed = transformed.replacingOccurrences(of: " \(punctuation)", with: punctuation)
        }
        for punctuation in ["(", "["] {
            transformed = transformed.replacingOccurrences(of: "\(punctuation) ", with: punctuation)
            transformed = transformed.replacingOccurrences(of: " \(punctuation)", with: punctuation)
        }
        transformed = transformed.replacingOccurrences(of: " \n", with: "\n")
        return transformed.replacingOccurrences(of: "\n ", with: "\n")
    }
}
