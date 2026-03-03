import XCTest
@testable import LocalSTTCore

final class ReplacementManagerTests: XCTestCase {

    // MARK: - Rule Management

    func testAddRule() {
        let manager = ReplacementManager(rules: [])
        let (success, error) = manager.addRule(from: "Cloud Code", to: "Claude Code")
        XCTAssertTrue(success)
        XCTAssertNil(error)
        XCTAssertEqual(manager.rules.count, 1)
        XCTAssertEqual(manager.rules[0].from, "Cloud Code")
        XCTAssertEqual(manager.rules[0].to, "Claude Code")
    }

    func testRemoveRule() {
        let rule = ReplacementRule(from: "Cloud Code", to: "Claude Code")
        let manager = ReplacementManager(rules: [rule])
        XCTAssertEqual(manager.rules.count, 1)

        let removed = manager.removeRule(rule)
        XCTAssertTrue(removed)
        XCTAssertEqual(manager.rules.count, 0)
    }

    func testDuplicateRuleRejected() {
        let manager = ReplacementManager(rules: [])
        _ = manager.addRule(from: "Cloud Code", to: "Claude Code")
        let (success, error) = manager.addRule(from: "cloud code", to: "Something") // case-insensitive dup
        XCTAssertFalse(success)
        XCTAssertNotNil(error)
        XCTAssertEqual(manager.rules.count, 1)
    }

    func testEmptyFromRejected() {
        let manager = ReplacementManager(rules: [])
        let (success, _) = manager.addRule(from: "  ", to: "something")
        XCTAssertFalse(success)
    }

    func testEmptyToRejected() {
        let manager = ReplacementManager(rules: [])
        let (success, _) = manager.addRule(from: "something", to: "  ")
        XCTAssertFalse(success)
    }

    func testMaxRulesEnforced() {
        let manager = ReplacementManager(rules: [])
        for i in 0..<ReplacementManager.maxRules {
            _ = manager.addRule(from: "from\(i)", to: "to\(i)")
        }
        XCTAssertEqual(manager.rules.count, ReplacementManager.maxRules)

        let (success, error) = manager.addRule(from: "overflow", to: "nope")
        XCTAssertFalse(success)
        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("limit"))
    }

    // MARK: - Apply Replacements

    func testApplyBasic() {
        let manager = ReplacementManager(rules: [
            ReplacementRule(from: "Cloud Code", to: "Claude Code"),
        ])
        let result = manager.applyReplacements(to: "I use Cloud Code daily")
        XCTAssertEqual(result, "I use Claude Code daily")
    }

    func testApplyCaseInsensitive() {
        let manager = ReplacementManager(rules: [
            ReplacementRule(from: "cloud code", to: "Claude Code"),
        ])
        let result = manager.applyReplacements(to: "I use CLOUD CODE daily")
        XCTAssertEqual(result, "I use Claude Code daily")
    }

    func testApplyWholeWordOnly() {
        let manager = ReplacementManager(rules: [
            ReplacementRule(from: "art", to: "ART"),
        ])
        // "art" should not match inside "start" or "smart"
        let result = manager.applyReplacements(to: "the art of starting smart")
        XCTAssertEqual(result, "the ART of starting smart")
    }

    func testApplySequentialOrder() {
        let manager = ReplacementManager(rules: [
            ReplacementRule(from: "foo", to: "bar"),
            ReplacementRule(from: "bar", to: "baz"),
        ])
        // "foo" → "bar", then "bar" → "baz" (sequential application)
        let result = manager.applyReplacements(to: "foo and bar")
        XCTAssertEqual(result, "baz and baz")
    }

    func testApplyDisabled() {
        let manager = ReplacementManager(rules: [
            ReplacementRule(from: "Cloud Code", to: "Claude Code"),
        ])
        manager.isEnabled = false
        let result = manager.applyReplacements(to: "I use Cloud Code daily")
        XCTAssertEqual(result, "I use Cloud Code daily")

        // Restore
        manager.isEnabled = true
    }

    func testApplyEmptyText() {
        let manager = ReplacementManager(rules: [
            ReplacementRule(from: "foo", to: "bar"),
        ])
        XCTAssertEqual(manager.applyReplacements(to: ""), "")
    }

    func testApplyNoRules() {
        let manager = ReplacementManager(rules: [])
        XCTAssertEqual(manager.applyReplacements(to: "hello world"), "hello world")
    }

    // MARK: - Template Escaping

    func testAmpersandInReplacement() {
        // NSRegularExpression treats & as "whole match" in templates.
        // "r and d" → "R&D" must output literal "R&D", not the matched text.
        let manager = ReplacementManager(rules: [
            ReplacementRule(from: "r and d", to: "R&D"),
        ])
        let result = manager.applyReplacements(to: "our r and d team")
        XCTAssertEqual(result, "our R&D team")
    }

    func testDollarSignInReplacement() {
        let manager = ReplacementManager(rules: [
            ReplacementRule(from: "cost", to: "CO$T"),
        ])
        let result = manager.applyReplacements(to: "the cost is high")
        XCTAssertEqual(result, "the CO$T is high")
    }

    func testBackslashInReplacement() {
        let manager = ReplacementManager(rules: [
            ReplacementRule(from: "path", to: "A\\B"),
        ])
        let result = manager.applyReplacements(to: "the path here")
        XCTAssertEqual(result, "the A\\B here")
    }

    // MARK: - File I/O

    func testFileRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create manager and add rules
        let manager = ReplacementManager(directoryURL: tempDir)
        _ = manager.addRule(from: "Cloud Code", to: "Claude Code")
        _ = manager.addRule(from: "chat GPT", to: "ChatGPT")

        // Create a new manager reading from the same directory
        let manager2 = ReplacementManager(directoryURL: tempDir)
        XCTAssertEqual(manager2.rules.count, 2)
        XCTAssertEqual(manager2.rules[0].from, "Cloud Code")
        XCTAssertEqual(manager2.rules[1].from, "chat GPT")
    }
}
