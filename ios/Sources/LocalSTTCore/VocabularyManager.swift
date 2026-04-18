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
    private let usageFileURL: URL?
    private let _words: ManagedWords
    private let _usage: ManagedUsage

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

    /// Thread-safe wrapper for usage counts.
    private final class ManagedUsage: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: Int] = [:]

        var value: [String: Int] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func set(_ newValue: [String: Int]) {
            lock.lock()
            defer { lock.unlock() }
            storage = newValue
        }

        func increment(_ keys: [String]) {
            lock.lock()
            defer { lock.unlock() }
            for key in keys {
                storage[key, default: 0] += 1
            }
        }
    }

    /// Current vocabulary words.
    public var words: [String] { _words.value }

    /// Usage counts keyed by vocabulary word (case-sensitive).
    public var usageCounts: [String: Int] { _usage.value }

    /// Initialize with a vocabulary file URL.
    ///
    /// On first launch, copies the bundled vocabulary to the writable location
    /// (Application Support) if it doesn't exist yet.
    ///
    /// - Parameters:
    ///   - bundledFileURL: URL of the bundled vocabulary.txt in the app bundle
    ///   - writableDirectoryURL: Writable directory for the working copy (defaults to Application Support)
    public init(bundledFileURL: URL? = nil, bundledUsageURL: URL? = nil, writableDirectoryURL: URL? = nil) {
        let appSupport = writableDirectoryURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("LocalSTT")

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        self.fileURL = appSupport.appendingPathComponent("vocabulary.txt")
        self.usageFileURL = appSupport.appendingPathComponent("vocabulary_usage.json")
        self._words = ManagedWords()
        self._usage = ManagedUsage()

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

        // Copy bundled usage file on first launch
        if let usageURL = usageFileURL,
           !FileManager.default.fileExists(atPath: usageURL.path),
           let bundledUsage = bundledUsageURL {
            try? FileManager.default.copyItem(at: bundledUsage, to: usageURL)
        }

        loadFromFile()
        loadUsageFromFile()

        // Re-seed from bundle if writable file has no words (app upgrade scenario:
        // the file existed before bundled data was added, so copy-on-first-launch was skipped)
        if _words.value.isEmpty, let bundled = bundledFileURL,
           FileManager.default.fileExists(atPath: bundled.path) {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.copyItem(at: bundled, to: fileURL)
            loadFromFile()
        }
        if _usage.value.isEmpty, let usageURL = usageFileURL, let bundledUsage = bundledUsageURL,
           FileManager.default.fileExists(atPath: bundledUsage.path) {
            try? FileManager.default.removeItem(at: usageURL)
            try? FileManager.default.copyItem(at: bundledUsage, to: usageURL)
            loadUsageFromFile()
        }

        // Merge bundled vocabulary into working copy on every launch.
        // This picks up new words added on macOS without losing iOS-only words.
        if !_words.value.isEmpty, let bundled = bundledFileURL,
           FileManager.default.fileExists(atPath: bundled.path) {
            mergeWordsFromBundle(bundled)
        }
        if let bundledUsage = bundledUsageURL,
           FileManager.default.fileExists(atPath: bundledUsage.path) {
            mergeUsageFromBundle(bundledUsage)
        }
    }

    /// Initialize with an explicit word list (for testing).
    public init(words: [String]) {
        self.fileURL = URL(fileURLWithPath: "/dev/null")
        self.usageFileURL = nil
        self._words = ManagedWords()
        self._usage = ManagedUsage()
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

    /// Save current vocabulary to the file, reordered by usage (most-used first).
    public func saveToFile() {
        reorderByUsage()

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

    // MARK: - Usage Tracking

    /// Record usage for matched vocabulary words.
    public func recordUsage(for matchedWords: [String]) {
        guard !matchedWords.isEmpty else { return }
        _usage.increment(matchedWords)
        saveUsageToFile()
    }

    /// Sort words descending by usage count (stable sort for ties).
    private func reorderByUsage() {
        let counts = _usage.value
        guard !counts.isEmpty else { return }

        var current = _words.value
        current.sort { a, b in
            let countA = counts[a] ?? 0
            let countB = counts[b] ?? 0
            return countA > countB
        }
        _words.set(current)
    }

    private func loadUsageFromFile() {
        guard let url = usageFileURL,
              let data = try? Data(contentsOf: url),
              let counts = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return }
        _usage.set(counts)
    }

    private func saveUsageToFile() {
        guard let url = usageFileURL else { return }
        guard let data = try? JSONEncoder().encode(_usage.value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Bundle Merge

    /// Merge words from the bundled vocabulary into the working copy (additive).
    /// New words from the bundle are appended; existing words are preserved.
    private func mergeWordsFromBundle(_ bundledURL: URL) {
        guard let content = try? String(contentsOf: bundledURL, encoding: .utf8) else { return }
        let bundledWords = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        let currentWords = _words.value
        let currentLower = Set(currentWords.map { $0.lowercased() })

        var merged = currentWords
        for word in bundledWords {
            if !currentLower.contains(word.lowercased()) && merged.count < Self.maxVocabularySize {
                merged.append(word)
            }
        }

        if merged.count != currentWords.count {
            _words.set(merged)
            saveToFile()
        }
    }

    /// Merge usage counts from the bundled file, taking the max of each word's count.
    private func mergeUsageFromBundle(_ bundledURL: URL) {
        guard let data = try? Data(contentsOf: bundledURL),
              let bundledCounts = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return }

        var currentCounts = _usage.value
        var changed = false
        for (word, count) in bundledCounts {
            let current = currentCounts[word] ?? 0
            if count > current {
                currentCounts[word] = count
                changed = true
            }
        }

        if changed {
            _usage.set(currentCounts)
            saveUsageToFile()
        }
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

}
