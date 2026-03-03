import XCTest
@testable import LocalSTTCore

final class TranscriptionResultTests: XCTestCase {

    // MARK: - Initialization

    func testDefaultInit() {
        let result = TranscriptionResult(
            text: "Hello world",
            language: "en",
            duration: 2.5,
            processingTime: 0.8
        )

        XCTAssertEqual(result.text, "Hello world")
        XCTAssertEqual(result.language, "en")
        XCTAssertEqual(result.duration, 2.5)
        XCTAssertEqual(result.processingTime, 0.8)
        XCTAssertNotNil(result.id)
        XCTAssertNotNil(result.timestamp)
    }

    // MARK: - Formatting

    func testFormattedDurationSeconds() {
        let result = makeResult(duration: 3.7)
        XCTAssertEqual(result.formattedDuration, "3.7s")
    }

    func testFormattedDurationMinutes() {
        let result = makeResult(duration: 125.0)
        XCTAssertEqual(result.formattedDuration, "2:05")
    }

    func testFormattedDurationSubSecond() {
        let result = makeResult(duration: 0.5)
        XCTAssertEqual(result.formattedDuration, "0.5s")
    }

    func testFormattedProcessingTime() {
        let result = makeResult(processingTime: 1.23)
        XCTAssertEqual(result.formattedProcessingTime, "1.2s")
    }

    // MARK: - Codable

    func testCodableRoundTrip() throws {
        let original = TranscriptionResult(
            text: "Test transcription with Unicode: 你好",
            language: "zh",
            duration: 5.0,
            processingTime: 1.2,
            timestamp: Date(timeIntervalSince1970: 1700000000)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptionResult.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.text, original.text)
        XCTAssertEqual(decoded.language, original.language)
        XCTAssertEqual(decoded.duration, original.duration)
        XCTAssertEqual(decoded.processingTime, original.processingTime)
        XCTAssertEqual(decoded.timestamp, original.timestamp)
    }

    func testCodableArray() throws {
        let results = [
            makeResult(text: "First"),
            makeResult(text: "Second"),
            makeResult(text: "Third"),
        ]

        let data = try JSONEncoder().encode(results)
        let decoded = try JSONDecoder().decode([TranscriptionResult].self, from: data)
        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[0].text, "First")
        XCTAssertEqual(decoded[2].text, "Third")
    }

    // MARK: - Identity

    func testUniqueIDs() {
        let a = makeResult()
        let b = makeResult()
        XCTAssertNotEqual(a.id, b.id)
    }

    // MARK: - Helpers

    private func makeResult(
        text: String = "test",
        duration: TimeInterval = 1.0,
        processingTime: TimeInterval = 0.5
    ) -> TranscriptionResult {
        TranscriptionResult(
            text: text,
            language: "en",
            duration: duration,
            processingTime: processingTime
        )
    }
}
