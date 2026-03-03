import XCTest
@testable import LocalSTTCore

final class HallucinationFilterTests: XCTestCase {

    // MARK: - Known Phrases

    func testKnownEnglishPhrases() {
        XCTAssertTrue(HallucinationFilter.isHallucination("Thank you"))
        XCTAssertTrue(HallucinationFilter.isHallucination("thank you."))
        XCTAssertTrue(HallucinationFilter.isHallucination("Thanks for watching."))
        XCTAssertTrue(HallucinationFilter.isHallucination("Thanks for listening"))
        XCTAssertTrue(HallucinationFilter.isHallucination("Like and subscribe"))
        XCTAssertTrue(HallucinationFilter.isHallucination("Subscribe."))
        XCTAssertTrue(HallucinationFilter.isHallucination("See you next time."))
        XCTAssertTrue(HallucinationFilter.isHallucination("Bye"))
        XCTAssertTrue(HallucinationFilter.isHallucination("Goodbye."))
        XCTAssertTrue(HallucinationFilter.isHallucination("you"))
        XCTAssertTrue(HallucinationFilter.isHallucination("you."))
    }

    func testKnownChinesePhrases() {
        XCTAssertTrue(HallucinationFilter.isHallucination("謝謝"))
        XCTAssertTrue(HallucinationFilter.isHallucination("谢谢"))
        XCTAssertTrue(HallucinationFilter.isHallucination("謝謝觀看"))
        XCTAssertTrue(HallucinationFilter.isHallucination("谢谢观看"))
    }

    func testKnownJapanesePhrases() {
        XCTAssertTrue(HallucinationFilter.isHallucination("ありがとう"))
        XCTAssertTrue(HallucinationFilter.isHallucination("ありがとうございます"))
        XCTAssertTrue(HallucinationFilter.isHallucination("ご視聴ありがとうございました"))
    }

    func testKnownFrenchPhrases() {
        XCTAssertTrue(HallucinationFilter.isHallucination("Merci"))
        XCTAssertTrue(HallucinationFilter.isHallucination("merci."))
        XCTAssertTrue(HallucinationFilter.isHallucination("merci d'avoir regardé"))
    }

    func testEllipsis() {
        XCTAssertTrue(HallucinationFilter.isHallucination("..."))
        XCTAssertTrue(HallucinationFilter.isHallucination("…"))
    }

    // MARK: - Non-Hallucinations

    func testPartialPhraseNotHallucination() {
        // Partial match should NOT be filtered
        XCTAssertFalse(HallucinationFilter.isHallucination("Thank you for the help"))
        XCTAssertFalse(HallucinationFilter.isHallucination("I want to subscribe to the newsletter"))
        XCTAssertFalse(HallucinationFilter.isHallucination("Thanks for your presentation today"))
    }

    func testNormalTextNotHallucination() {
        XCTAssertFalse(HallucinationFilter.isHallucination("The weather is nice today"))
        XCTAssertFalse(HallucinationFilter.isHallucination("Please send me the report"))
        XCTAssertFalse(HallucinationFilter.isHallucination("Hello world"))
    }

    func testEmptyStringNotHallucination() {
        XCTAssertFalse(HallucinationFilter.isHallucination(""))
        XCTAssertFalse(HallucinationFilter.isHallucination("   "))
    }

    // MARK: - Case Insensitive

    func testCaseInsensitive() {
        XCTAssertTrue(HallucinationFilter.isHallucination("THANK YOU"))
        XCTAssertTrue(HallucinationFilter.isHallucination("Thank You."))
        XCTAssertTrue(HallucinationFilter.isHallucination("SUBSCRIBE"))
        XCTAssertTrue(HallucinationFilter.isHallucination("BYE"))
        XCTAssertTrue(HallucinationFilter.isHallucination("MERCI"))
    }

    // MARK: - Whitespace Trimming

    func testWhitespaceTrimmed() {
        XCTAssertTrue(HallucinationFilter.isHallucination("  thank you  "))
        XCTAssertTrue(HallucinationFilter.isHallucination("\n thank you \n"))
        XCTAssertTrue(HallucinationFilter.isHallucination("\tbye\t"))
    }

    // MARK: - Apostrophe Normalization

    func testTypographicApostrophe() {
        // Whisper may return U+2019 (right single quotation mark) instead of U+0027
        XCTAssertTrue(HallucinationFilter.isHallucination("merci d\u{2019}avoir regard\u{00E9}"))
    }
}
