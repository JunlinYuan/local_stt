import XCTest
@testable import LocalSTTCore

final class VocabularyManagerTests: XCTestCase {

    // MARK: - Initialization

    func testInitWithWordList() {
        let manager = VocabularyManager(words: ["MCP", "TEMPEST", "Claude Code"])
        XCTAssertEqual(manager.words, ["MCP", "TEMPEST", "Claude Code"])
    }

    func testInitEnforcesMaxSize() {
        let words = (0..<100).map { "word\($0)" }
        let manager = VocabularyManager(words: words)
        XCTAssertEqual(manager.words.count, VocabularyManager.maxVocabularySize)
    }

    func testMaxVocabularySize() {
        XCTAssertEqual(VocabularyManager.maxVocabularySize, 85)
    }

    // MARK: - Prompt Building (ported from groq_stt.py:_build_prompt)

    func testBuildPromptBasic() {
        let manager = VocabularyManager(words: ["MCP", "TEMPEST", "STT"])
        let prompt = manager.buildPrompt()
        XCTAssertEqual(prompt, "Vocabulary: MCP, TEMPEST, STT.")
    }

    func testBuildPromptEmptyVocabulary() {
        let manager = VocabularyManager(words: [])
        XCTAssertNil(manager.buildPrompt())
    }

    func testBuildPromptMaxWords() {
        let manager = VocabularyManager(words: ["MCP", "TEMPEST", "STT", "DNS", "CLI"])
        let prompt = manager.buildPrompt(maxWords: 3)
        XCTAssertEqual(prompt, "Vocabulary: MCP, TEMPEST, STT.")
    }

    func testBuildPromptTruncation() {
        // Create words that will exceed 896 chars
        let longWords = (0..<200).map { "LongVocabularyWord\($0)" }
        let manager = VocabularyManager(words: longWords)
        let prompt = manager.buildPrompt()

        XCTAssertNotNil(prompt)
        XCTAssertLessThanOrEqual(prompt!.count, VocabularyManager.maxPromptLength)
        XCTAssertTrue(prompt!.hasPrefix("Vocabulary: "))
        XCTAssertTrue(prompt!.hasSuffix("."))
    }

    func testBuildPromptFormat() {
        let manager = VocabularyManager(words: ["alpha", "beta"])
        let prompt = manager.buildPrompt()!

        // Must match the Python format exactly
        XCTAssertTrue(prompt.hasPrefix("Vocabulary: "))
        XCTAssertTrue(prompt.hasSuffix("."))
        XCTAssertTrue(prompt.contains(", "))
    }

    func testBuildPromptSingleWord() {
        let manager = VocabularyManager(words: ["MCP"])
        let prompt = manager.buildPrompt()
        XCTAssertEqual(prompt, "Vocabulary: MCP.")
    }

    func testBuildPromptMaxLength896() {
        // Verify the 896 char limit is enforced
        XCTAssertEqual(VocabularyManager.maxPromptLength, 896)
    }

    // MARK: - Word Management

    func testAddWord() {
        let manager = VocabularyManager(words: ["MCP"])
        let (success, error) = manager.addWord("TEMPEST")
        XCTAssertTrue(success)
        XCTAssertNil(error)
        XCTAssertEqual(manager.words, ["MCP", "TEMPEST"])
    }

    func testAddDuplicateWord() {
        let manager = VocabularyManager(words: ["MCP"])
        let (success, error) = manager.addWord("mcp") // case-insensitive duplicate
        XCTAssertFalse(success)
        XCTAssertEqual(error, "Word already exists")
    }

    func testAddEmptyWord() {
        let manager = VocabularyManager(words: [])
        let (success, error) = manager.addWord("  ")
        XCTAssertFalse(success)
        XCTAssertEqual(error, "Empty word")
    }

    func testRemoveWord() {
        let manager = VocabularyManager(words: ["MCP", "TEMPEST", "STT"])
        let removed = manager.removeWord("tempest") // case-insensitive
        XCTAssertTrue(removed)
        XCTAssertEqual(manager.words, ["MCP", "STT"])
    }

    func testRemoveNonexistentWord() {
        let manager = VocabularyManager(words: ["MCP"])
        let removed = manager.removeWord("NOPE")
        XCTAssertFalse(removed)
    }

    func testSetWords() {
        let manager = VocabularyManager(words: ["old"])
        manager.setWords(["new1", "new2", "new3"])
        XCTAssertEqual(manager.words, ["new1", "new2", "new3"])
    }

    func testSetWordsTrimsAndFilters() {
        let manager = VocabularyManager(words: [])
        manager.setWords(["  hello  ", "", "  ", "world"])
        XCTAssertEqual(manager.words, ["hello", "world"])
    }

    // MARK: - File I/O

    func testFileRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create manager with writable directory
        let manager = VocabularyManager(writableDirectoryURL: tempDir)
        manager.setWords(["Alpha", "Beta", "Gamma"])

        // Create a new manager reading from the same directory
        let manager2 = VocabularyManager(writableDirectoryURL: tempDir)
        XCTAssertEqual(manager2.words, ["Alpha", "Beta", "Gamma"])
    }

    func testBundledFileCopy() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a "bundled" vocabulary file
        let bundledURL = tempDir.appendingPathComponent("bundled_vocab.txt")
        try "MCP\nTEMPEST\nSTT\n".write(to: bundledURL, atomically: true, encoding: .utf8)

        // Create another writable directory
        let writableDir = tempDir.appendingPathComponent("writable")

        let manager = VocabularyManager(
            bundledFileURL: bundledURL,
            writableDirectoryURL: writableDir
        )
        XCTAssertEqual(manager.words, ["MCP", "TEMPEST", "STT"])
    }

    func testLoadSkipsCommentsAndBlanks() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Write file with comments and blanks
        let vocabFile = tempDir.appendingPathComponent("vocabulary.txt")
        let content = """
        # This is a comment
        MCP

        # Another comment
        TEMPEST
        STT
        """
        try content.write(to: vocabFile, atomically: true, encoding: .utf8)

        let manager = VocabularyManager(writableDirectoryURL: tempDir)
        XCTAssertEqual(manager.words, ["MCP", "TEMPEST", "STT"])
    }

    // MARK: - Usage Tracking

    func testRecordUsage() {
        let manager = VocabularyManager(words: ["MCP", "TEMPEST", "STT"])
        manager.recordUsage(for: ["MCP", "STT"])
        manager.recordUsage(for: ["MCP"])

        XCTAssertEqual(manager.usageCounts["MCP"], 2)
        XCTAssertEqual(manager.usageCounts["STT"], 1)
        XCTAssertNil(manager.usageCounts["TEMPEST"])
    }

    func testUsageCounts() {
        let manager = VocabularyManager(words: ["alpha", "beta"])
        XCTAssertTrue(manager.usageCounts.isEmpty)

        manager.recordUsage(for: ["alpha"])
        XCTAssertEqual(manager.usageCounts["alpha"], 1)
    }

    func testReorderByUsage() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manager = VocabularyManager(writableDirectoryURL: tempDir)
        manager.setWords(["alpha", "beta", "gamma"])

        // Record usage: gamma=3, alpha=1, beta=0
        manager.recordUsage(for: ["gamma", "gamma", "gamma"])
        manager.recordUsage(for: ["alpha"])

        // saveToFile() calls reorderByUsage() internally
        manager.saveToFile()

        // After reorder: gamma (3), alpha (1), beta (0)
        XCTAssertEqual(manager.words[0], "gamma")
        XCTAssertEqual(manager.words[1], "alpha")
        XCTAssertEqual(manager.words[2], "beta")
    }

    func testUsageFileRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manager = VocabularyManager(writableDirectoryURL: tempDir)
        manager.setWords(["MCP", "TEMPEST"])
        manager.recordUsage(for: ["MCP", "MCP", "TEMPEST"])

        // New manager should load usage counts from file
        let manager2 = VocabularyManager(writableDirectoryURL: tempDir)
        XCTAssertEqual(manager2.usageCounts["MCP"], 2)
        XCTAssertEqual(manager2.usageCounts["TEMPEST"], 1)
    }

    func testRecordUsageEmptyDoesNothing() {
        let manager = VocabularyManager(words: ["MCP"])
        manager.recordUsage(for: [])
        XCTAssertTrue(manager.usageCounts.isEmpty)
    }
}
