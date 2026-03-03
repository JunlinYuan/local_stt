import Foundation

/// Manages custom vocabulary for STT prompt biasing and casing correction.
///
/// Ported from `backend/vocabulary.py` and `backend/groq_stt.py:_build_prompt()`.
/// Loads vocabulary from a text file, builds Groq-compatible prompts, and applies
/// canonical casing to transcription results.
public final class VocabularyManager: Sendable {
    /// Maximum vocabulary size (matches Python `MAX_VOCABULARY_SIZE`).
    public static let maxVocabularySize = 85

    /// Groq's prompt character limit.
    public static let maxPromptLength = 896

    private let fileURL: URL
    private let _words: ManagedWords

    /// Thread-safe wrapper for mutable word list.
    private final class ManagedWords: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        var value: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func set(_ newValue: [String]) {
            lock.lock()
            defer { lock.unlock() }
            storage = newValue
        }
    }

    /// Current vocabulary words.
    public var words: [String] { _words.value }

    /// Initialize with a vocabulary file URL.
    ///
    /// On first launch, copies the bundled vocabulary to the writable location
    /// (Application Support) if it doesn't exist yet.
    ///
    /// - Parameters:
    ///   - bundledFileURL: URL of the bundled vocabulary.txt in the app bundle
    ///   - writableDirectoryURL: Writable directory for the working copy (defaults to Application Support)
    public init(bundledFileURL: URL? = nil, writableDirectoryURL: URL? = nil) {
        let appSupport = writableDirectoryURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("LocalSTT")

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        self.fileURL = appSupport.appendingPathComponent("vocabulary.txt")
        self._words = ManagedWords()

        // Copy bundled file on first launch
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            if let bundled = bundledFileURL {
                try? FileManager.default.copyItem(at: bundled, to: fileURL)
            } else {
                // Create empty file with header
                let header = """
                # Custom vocabulary for speech-to-text
                # One word/phrase per line, comments start with #
                # Words are case-sensitive (TEMPEST stays TEMPEST)

                """
                try? header.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }

        loadFromFile()
    }

    /// Initialize with an explicit word list (for testing).
    public init(words: [String]) {
        self.fileURL = URL(fileURLWithPath: "/dev/null")
        self._words = ManagedWords()
        self._words.set(Array(words.prefix(Self.maxVocabularySize)))
    }

    // MARK: - File I/O

    /// Load vocabulary from the file.
    public func loadFromFile() {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }

        let loaded = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        _words.set(Array(loaded.prefix(Self.maxVocabularySize)))
    }

    /// Save current vocabulary to the file.
    public func saveToFile() {
        var lines = [
            "# Custom vocabulary for speech-to-text",
            "# One word/phrase per line, comments start with #",
            "# Words are case-sensitive (TEMPEST stays TEMPEST)",
            "",
        ]
        lines.append(contentsOf: words)
        lines.append("") // trailing newline

        let content = lines.joined(separator: "\n")
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Word Management

    /// Add a word. Returns (success, errorMessage).
    public func addWord(_ word: String) -> (Bool, String?) {
        let trimmed = word.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return (false, "Empty word") }

        if words.count >= Self.maxVocabularySize {
            return (false, "Vocabulary limit reached (\(Self.maxVocabularySize) words). Remove a word first.")
        }

        if words.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return (false, "Word already exists")
        }

        var current = words
        current.append(trimmed)
        _words.set(current)
        saveToFile()
        return (true, nil)
    }

    /// Remove a word (case-insensitive match). Returns true if removed.
    public func removeWord(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespaces)
        var current = words
        guard let index = current.firstIndex(where: {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }) else { return false }

        current.remove(at: index)
        _words.set(current)
        saveToFile()
        return true
    }

    /// Replace entire vocabulary.
    public func setWords(_ newWords: [String]) {
        let cleaned = newWords
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        _words.set(Array(cleaned.prefix(Self.maxVocabularySize)))
        saveToFile()
    }

    // MARK: - Prompt Building (ported from groq_stt.py:_build_prompt)

    /// Build a Groq-compatible vocabulary prompt.
    ///
    /// Format: `"Vocabulary: word1, word2, word3."` truncated to 896 chars.
    /// Returns nil if vocabulary is empty.
    public func buildPrompt(maxWords: Int = 0) -> String? {
        let vocab = words
        guard !vocab.isEmpty else { return nil }

        let source = maxWords > 0 ? Array(vocab.prefix(maxWords)) : vocab

        let prefix = "Vocabulary: "
        let suffix = "."
        var currentLength = prefix.count + suffix.count
        var included: [String] = []

        for word in source {
            let separator = included.isEmpty ? "" : ", "
            let addition = separator.count + word.count

            if currentLength + addition <= Self.maxPromptLength {
                included.append(word)
                currentLength += addition
            } else {
                break
            }
        }

        guard !included.isEmpty else { return nil }
        return "\(prefix)\(included.joined(separator: ", "))\(suffix)"
    }

    // MARK: - Casing Correction (ported from vocabulary_utils.py)

    /// Apply canonical vocabulary casing to transcribed text.
    ///
    /// Uses word-boundary regex matching (case-insensitive) to replace
    /// each occurrence with the vocabulary's canonical form.
    ///
    /// - Parameter text: Raw transcription text
    /// - Returns: Tuple of (corrected text, list of matched vocabulary words)
    public func applyVocabularyCasing(to text: String) -> (String, [String]) {
        let vocab = words
        guard !vocab.isEmpty else { return (text, []) }

        var result = text
        var matched: [String] = []

        for word in vocab {
            let escaped = NSRegularExpression.escapedPattern(for: word)
            // \b word boundary — note: ICU regex \b handles most cases but
            // may differ from Python re for hyphenated words
            guard let regex = try? NSRegularExpression(
                pattern: "\\b\(escaped)\\b",
                options: .caseInsensitive
            ) else { continue }

            let range = NSRange(result.startIndex..., in: result)
            if regex.firstMatch(in: result, range: range) != nil {
                matched.append(word)
                // Escape replacement template — $0, $1, \0 etc. have special meaning
                let escapedTemplate = word
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "$", with: "\\$")
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: escapedTemplate
                )
            }
        }

        return (result, matched)
    }
}
