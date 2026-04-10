import Foundation

/// Detects known Whisper hallucination phrases (phantom output from silent/quiet audio).
///
/// Ported from `backend/content_filter.py`. These phrases are filtered only when they
/// constitute the ENTIRE transcription — partial matches are ignored.
/// Always on, no toggle needed.
public enum HallucinationFilter {
    /// Known Whisper hallucination phrases, normalized to lowercase.
    /// Periods are included as separate entries to match both "thank you" and "thank you."
    private static let phrases: Set<String> = [
        // English
        "thank you",
        "thank you.",
        "thanks",
        "thanks.",
        "thanks for watching",
        "thanks for watching.",
        "thanks for listening",
        "thanks for listening.",
        "thank you for watching",
        "thank you for watching.",
        "thank you for listening",
        "thank you for listening.",
        "like and subscribe",
        "like and subscribe.",
        "subscribe",
        "subscribe.",
        "see you next time",
        "see you next time.",
        "bye",
        "bye.",
        "goodbye",
        "goodbye.",
        "see you",
        "see you.",
        // Chinese
        "謝謝",
        "谢谢",
        "謝謝觀看",
        "谢谢观看",
        // Japanese
        "ありがとう",
        "ありがとうございます",
        "ご視聴ありがとうございました",
        // French
        "merci",
        "merci.",
        "merci d'avoir regardé",
        // Other common ones
        "...",
        "…",
        "you",
        "you.",
    ]

    /// Check if text is a known Whisper hallucination.
    ///
    /// Returns `true` only if the **entire** text (after trimming whitespace,
    /// lowercasing, and normalizing typographic apostrophes) matches a known phrase.
    public static func isHallucination(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'") // ' → '
        guard !normalized.isEmpty else { return false }
        return phrases.contains(normalized)
    }
}
