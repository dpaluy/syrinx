import Foundation

/// Formats successful transcription output before it reaches the text injector.
public enum TextOutputPolicy {
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

    /// Returns nil when the sanitized transcript is empty.
    public static func output(for text: String, addTrailingSpace: Bool) -> String? {
        let sanitized = sanitize(text)
        guard !sanitized.isEmpty else { return nil }
        return addTrailingSpace ? sanitized + " " : sanitized
    }

    public static func apply(to text: String, addTrailingSpace: Bool) -> String? {
        output(for: text, addTrailingSpace: addTrailingSpace)
    }

    public static func apply(_ text: String, addTrailingSpace: Bool) -> String? {
        output(for: text, addTrailingSpace: addTrailingSpace)
    }
}
