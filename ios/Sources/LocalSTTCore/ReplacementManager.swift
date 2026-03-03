import Foundation

/// Manages word replacement rules with file persistence.
///
/// Ported from `backend/replacements.py`. Rules are applied case-insensitively
/// with whole-word boundary matching via NSRegularExpression.
public final class ReplacementManager: Sendable {
    /// Maximum number of replacement rules.
    public static let maxRules = 100

    private static let enabledKey = "replacements_enabled"

    private let fileURL: URL?
    private let _rules: ManagedRules

    /// Thread-safe wrapper for mutable rules list with pre-compiled regex patterns.
    private final class ManagedRules: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [ReplacementRule] = []
        /// Pre-compiled regex for each rule (indexed in parallel with storage).
        private var compiledRegex: [NSRegularExpression?] = []

        var value: [ReplacementRule] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        var regexPatterns: [NSRegularExpression?] {
            lock.lock()
            defer { lock.unlock() }
            return compiledRegex
        }

        /// Fetch rules and their pre-compiled regex atomically under a single lock.
        func valueAndPatterns() -> ([ReplacementRule], [NSRegularExpression?]) {
            lock.lock()
            defer { lock.unlock() }
            return (storage, compiledRegex)
        }

        func set(_ newValue: [ReplacementRule]) {
            lock.lock()
            defer { lock.unlock() }
            storage = newValue
            compiledRegex = newValue.map { rule in
                let escaped = NSRegularExpression.escapedPattern(for: rule.from)
                return try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: .caseInsensitive)
            }
        }
    }

    /// Current replacement rules.
    public var rules: [ReplacementRule] { _rules.value }

    /// Whether replacements are enabled (persisted in UserDefaults).
    public var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    // MARK: - Init

    /// Initialize with file-based storage.
    ///
    /// File location: `ApplicationSupport/LocalSTT/replacements.json`
    public init(bundledFileURL: URL? = nil, directoryURL: URL? = nil) {
        let appSupport = directoryURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("LocalSTT")

        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        self.fileURL = appSupport.appendingPathComponent("replacements.json")
        self._rules = ManagedRules()

        // Set default enabled state on first launch
        if UserDefaults.standard.object(forKey: Self.enabledKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
        }

        // Copy bundled replacements on first launch
        if !FileManager.default.fileExists(atPath: fileURL!.path),
           let bundled = bundledFileURL {
            try? FileManager.default.copyItem(at: bundled, to: fileURL!)
        }

        loadFromFile()
    }

    /// Initialize with an explicit rule list (for testing).
    public init(rules: [ReplacementRule]) {
        self.fileURL = nil
        self._rules = ManagedRules()
        self._rules.set(Array(rules.prefix(Self.maxRules)))

        if UserDefaults.standard.object(forKey: Self.enabledKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
        }
    }

    // MARK: - File I/O

    /// JSON structure: `{"replacements": [{"from":"…","to":"…"}, ...]}`
    private struct FileFormat: Codable {
        let replacements: [ReplacementRule]
    }

    private func loadFromFile() {
        guard let url = fileURL else { return }
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(FileFormat.self, from: data)
        else { return }

        _rules.set(Array(file.replacements.prefix(Self.maxRules)))
    }

    private func saveToFile() {
        guard let url = fileURL else { return }
        let file = FileFormat(replacements: rules)
        guard let data = try? JSONEncoder().encode(file) else { return }

        // Pretty-print for human readability
        if let json = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? pretty.write(to: url, options: .atomic)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Rule Management

    /// Add a replacement rule. Returns `(success, errorMessage)`.
    public func addRule(from: String, to: String) -> (Bool, String?) {
        let fromTrimmed = from.trimmingCharacters(in: .whitespaces)
        let toTrimmed = to.trimmingCharacters(in: .whitespaces)

        guard !fromTrimmed.isEmpty else { return (false, "Source text is required") }
        guard !toTrimmed.isEmpty else { return (false, "Replacement text is required") }

        if rules.count >= Self.maxRules {
            return (false, "Replacement limit reached (\(Self.maxRules) rules). Remove a rule first.")
        }

        // Case-insensitive duplicate check on `from`
        if rules.contains(where: { $0.from.caseInsensitiveCompare(fromTrimmed) == .orderedSame }) {
            return (false, "Replacement for '\(fromTrimmed)' already exists")
        }

        var current = rules
        current.append(ReplacementRule(from: fromTrimmed, to: toTrimmed))
        _rules.set(current)
        saveToFile()
        return (true, nil)
    }

    /// Remove a rule by ID. Returns `true` if removed.
    public func removeRule(_ rule: ReplacementRule) -> Bool {
        var current = rules
        guard let index = current.firstIndex(where: { $0.id == rule.id }) else { return false }
        current.remove(at: index)
        _rules.set(current)
        saveToFile()
        return true
    }

    // MARK: - Apply Replacements

    /// Apply all replacement rules to text sequentially.
    ///
    /// Matching is case-insensitive and whole-word only (using `\b` word boundaries).
    /// Uses pre-compiled regex patterns for performance.
    /// Returns original text if disabled or no rules match.
    public func applyReplacements(to text: String) -> String {
        guard isEnabled else { return text }

        let (currentRules, patterns) = _rules.valueAndPatterns()
        guard !currentRules.isEmpty, !text.isEmpty else { return text }

        var result = text
        for (rule, regex) in zip(currentRules, patterns) {
            guard let regex else { continue }

            let range = NSRange(result.startIndex..., in: result)
            // Escape replacement template — $, \, and & have special meaning in NSRegularExpression
            let escapedTemplate = rule.to
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "$", with: "\\$")
                .replacingOccurrences(of: "&", with: "\\&")
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: escapedTemplate
            )
        }

        return result
    }
}
