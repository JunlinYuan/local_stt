import XCTest
@testable import LocalSTTCore

final class GroqServiceTests: XCTestCase {

    private let service = GroqService(apiKey: "test-key-for-unit-tests")

    // MARK: - Multipart Body Building

    /// Search for an ASCII string pattern within binary Data.
    /// Unlike String(data:encoding:), this works even when the Data
    /// contains non-UTF-8 binary segments (like WAV audio).
    private func bodyContains(_ body: Data, ascii: String) -> Bool {
        guard let pattern = ascii.data(using: .ascii) else { return false }
        return body.range(of: pattern) != nil
    }

    func testMultipartBodyContainsModel() {
        let (body, contentType) = service.buildMultipartBody(
            wavData: makeMinimalWAV(), language: nil, prompt: nil
        )

        XCTAssertTrue(bodyContains(body, ascii: "whisper-large-v3-turbo"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
    }

    func testMultipartBodyContainsResponseFormat() {
        let (body, _) = service.buildMultipartBody(
            wavData: makeMinimalWAV(), language: nil, prompt: nil
        )

        XCTAssertTrue(bodyContains(body, ascii: "verbose_json"))
    }

    func testMultipartBodyIncludesLanguage() {
        let (body, _) = service.buildMultipartBody(
            wavData: makeMinimalWAV(), language: "fr", prompt: nil
        )

        XCTAssertTrue(bodyContains(body, ascii: "name=\"language\""))
        XCTAssertTrue(bodyContains(body, ascii: "fr"))
    }

    func testMultipartBodyOmitsLanguageWhenNil() {
        let (body, _) = service.buildMultipartBody(
            wavData: makeMinimalWAV(), language: nil, prompt: nil
        )

        XCTAssertFalse(bodyContains(body, ascii: "name=\"language\""))
    }

    func testMultipartBodyOmitsLanguageWhenEmpty() {
        let (body, _) = service.buildMultipartBody(
            wavData: makeMinimalWAV(), language: "", prompt: nil
        )

        XCTAssertFalse(bodyContains(body, ascii: "name=\"language\""))
    }

    func testMultipartBodyIncludesPrompt() {
        let prompt = "Vocabulary: MCP, TEMPEST, STT."
        let (body, _) = service.buildMultipartBody(
            wavData: makeMinimalWAV(), language: nil, prompt: prompt
        )

        XCTAssertTrue(bodyContains(body, ascii: "name=\"prompt\""))
        XCTAssertTrue(bodyContains(body, ascii: prompt))
    }

    func testMultipartBodyOmitsPromptWhenNil() {
        let (body, _) = service.buildMultipartBody(
            wavData: makeMinimalWAV(), language: nil, prompt: nil
        )

        XCTAssertFalse(bodyContains(body, ascii: "name=\"prompt\""))
    }

    func testMultipartBodyContainsFileField() {
        let (body, _) = service.buildMultipartBody(
            wavData: makeMinimalWAV(), language: nil, prompt: nil
        )

        XCTAssertTrue(bodyContains(body, ascii: "name=\"file\""))
        XCTAssertTrue(bodyContains(body, ascii: "filename=\"audio.wav\""))
        XCTAssertTrue(bodyContains(body, ascii: "audio/wav"))
    }

    func testMultipartBodyHasCorrectBoundary() {
        let (body, contentType) = service.buildMultipartBody(
            wavData: makeMinimalWAV(), language: nil, prompt: nil
        )

        let boundary = contentType.components(separatedBy: "boundary=").last!

        XCTAssertTrue(bodyContains(body, ascii: "--\(boundary)"))
        XCTAssertTrue(bodyContains(body, ascii: "--\(boundary)--"))
    }

    func testMultipartBodyContainsWAVData() {
        let (body, _) = service.buildMultipartBody(
            wavData: makeMinimalWAV(), language: nil, prompt: nil
        )

        // RIFF magic bytes
        let riffMagic = Data([0x52, 0x49, 0x46, 0x46])
        XCTAssertNotNil(body.range(of: riffMagic))
    }

    // MARK: - Error Messages

    func testGroqErrorMissingAPIKey() {
        let error = GroqError.missingAPIKey
        XCTAssertTrue(error.localizedDescription.contains("API key"))
    }

    func testGroqError401() {
        let error = GroqError.httpError(statusCode: 401, body: "Unauthorized")
        XCTAssertTrue(error.localizedDescription.contains("Invalid"))
    }

    func testGroqErrorOther() {
        let error = GroqError.httpError(statusCode: 500, body: "Server error")
        XCTAssertTrue(error.localizedDescription.contains("500"))
    }

    // MARK: - Response Decoding

    func testDecodeGroqResponse() throws {
        let json = """
        {
            "text": "Hello world",
            "language": "en",
            "duration": 2.5
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(GroqResponse.self, from: json)
        XCTAssertEqual(response.text, "Hello world")
        XCTAssertEqual(response.language, "en")
        XCTAssertEqual(response.duration, 2.5)
    }

    func testDecodeGroqResponseMinimal() throws {
        let json = """
        {
            "text": "Hello"
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(GroqResponse.self, from: json)
        XCTAssertEqual(response.text, "Hello")
        XCTAssertNil(response.language)
        XCTAssertNil(response.duration)
    }

    // MARK: - Helpers

    private func makeMinimalWAV() -> Data {
        let pcm = Data(count: 3200) // 0.1s of silence
        return WAVEncoder.encode(pcmData: pcm)
    }
}
