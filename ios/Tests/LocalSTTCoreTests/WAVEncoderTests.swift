import XCTest
@testable import LocalSTTCore

final class WAVEncoderTests: XCTestCase {

    // MARK: - Header Structure

    func testHeaderIsExactly44Bytes() {
        let pcm = Data(count: 0) // empty audio
        let wav = WAVEncoder.encode(pcmData: pcm)
        XCTAssertGreaterThanOrEqual(wav.count, 44, "WAV must have at least 44-byte header")
    }

    func testRIFFHeader() {
        let pcm = Data(count: 100)
        let wav = WAVEncoder.encode(pcmData: pcm)

        // "RIFF" at offset 0
        XCTAssertEqual(String(data: wav[0..<4], encoding: .ascii), "RIFF")

        // File size - 8 at offset 4 (little-endian UInt32)
        let fileSize = wav.littleEndianUInt32(at: 4)
        XCTAssertEqual(fileSize, UInt32(wav.count - 8))

        // "WAVE" at offset 8
        XCTAssertEqual(String(data: wav[8..<12], encoding: .ascii), "WAVE")
    }

    func testFmtSubChunk() {
        let pcm = Data(count: 100)
        let wav = WAVEncoder.encode(pcmData: pcm)

        // "fmt " at offset 12
        XCTAssertEqual(String(data: wav[12..<16], encoding: .ascii), "fmt ")

        // Sub-chunk size = 16 (PCM)
        XCTAssertEqual(wav.littleEndianUInt32(at: 16), 16)

        // Audio format = 1 (PCM)
        XCTAssertEqual(wav.littleEndianUInt16(at: 20), 1)

        // Channels = 1 (mono)
        XCTAssertEqual(wav.littleEndianUInt16(at: 22), 1)

        // Sample rate = 16000
        XCTAssertEqual(wav.littleEndianUInt32(at: 24), 16000)

        // Byte rate = 16000 * 1 * 2 = 32000
        XCTAssertEqual(wav.littleEndianUInt32(at: 28), 32000)

        // Block align = 1 * 2 = 2
        XCTAssertEqual(wav.littleEndianUInt16(at: 32), 2)

        // Bits per sample = 16
        XCTAssertEqual(wav.littleEndianUInt16(at: 34), 16)
    }

    func testDataSubChunk() {
        let pcmSize = 320 // 10ms of audio at 16kHz
        let pcm = Data(repeating: 0, count: pcmSize)
        let wav = WAVEncoder.encode(pcmData: pcm)

        // "data" at offset 36
        XCTAssertEqual(String(data: wav[36..<40], encoding: .ascii), "data")

        // Data size at offset 40
        XCTAssertEqual(wav.littleEndianUInt32(at: 40), UInt32(pcmSize))

        // Total size = 44 + PCM data
        XCTAssertEqual(wav.count, 44 + pcmSize)
    }

    func testPCMDataPreserved() {
        // Create known PCM pattern
        var pcm = Data()
        for i: Int16 in [100, -200, 300, -400, 500] {
            var sample = i.littleEndian
            pcm.append(Data(bytes: &sample, count: 2))
        }

        let wav = WAVEncoder.encode(pcmData: pcm)

        // Verify PCM data starts at offset 44
        let extractedPCM = wav[44...]
        XCTAssertEqual(Data(extractedPCM), pcm)
    }

    // MARK: - Duration Estimation

    func testDurationEstimation() {
        // 1 second of audio = 16000 samples * 2 bytes = 32000 bytes
        let oneSecondPCM = Data(count: 32000)
        let wav = WAVEncoder.encode(pcmData: oneSecondPCM)

        let duration = WAVEncoder.estimateDuration(from: wav)
        XCTAssertEqual(duration, 1.0, accuracy: 0.001)
    }

    func testDurationEstimationHalfSecond() {
        let halfSecondPCM = Data(count: 16000)
        let wav = WAVEncoder.encode(pcmData: halfSecondPCM)

        let duration = WAVEncoder.estimateDuration(from: wav)
        XCTAssertEqual(duration, 0.5, accuracy: 0.001)
    }

    func testDurationEstimationEmptyAudio() {
        let wav = WAVEncoder.encode(pcmData: Data())
        let duration = WAVEncoder.estimateDuration(from: wav)
        XCTAssertEqual(duration, 0.0, accuracy: 0.001)
    }

    func testDurationEstimationTooSmall() {
        let tooSmall = Data(count: 20) // Less than 44-byte header
        let duration = WAVEncoder.estimateDuration(from: tooSmall)
        XCTAssertEqual(duration, 0.0)
    }

    // MARK: - Constants

    func testConstants() {
        XCTAssertEqual(WAVEncoder.sampleRate, 16000)
        XCTAssertEqual(WAVEncoder.channels, 1)
        XCTAssertEqual(WAVEncoder.bitsPerSample, 16)
        XCTAssertEqual(WAVEncoder.bytesPerSample, 2)
    }
}

// MARK: - Data Helper for Reading Little-Endian Values

extension Data {
    func littleEndianUInt16(at offset: Int) -> UInt16 {
        let bytes = self[offset..<offset+2]
        return bytes.withUnsafeBytes { $0.load(as: UInt16.self) }.littleEndian
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        let bytes = self[offset..<offset+4]
        return bytes.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
    }
}
