import Foundation

/// Encodes raw PCM audio data into WAV format.
///
/// Produces a standard 44-byte RIFF header (not the 58-byte extensible format)
/// for maximum compatibility with Groq's Whisper API.
/// Format: 16-bit PCM, 16kHz, mono, little-endian.
public enum WAVEncoder {
    public static let sampleRate: Int = 16000
    public static let channels: Int = 1
    public static let bitsPerSample: Int = 16
    public static let bytesPerSample: Int = 2

    /// Encode raw Int16 PCM samples into a WAV file.
    ///
    /// - Parameter pcmData: Raw PCM audio as Data (Int16 little-endian samples)
    /// - Returns: Complete WAV file data with 44-byte RIFF header
    public static func encode(pcmData: Data) -> Data {
        let dataSize = UInt32(pcmData.count)
        let fileSize = 36 + dataSize // Total file size minus 8 bytes for RIFF header

        let byteRate = UInt32(sampleRate * channels * bytesPerSample)
        let blockAlign = UInt16(channels * bytesPerSample)

        var header = Data(capacity: 44)

        // RIFF chunk descriptor
        header.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        header.appendLittleEndian(fileSize)
        header.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        // fmt sub-chunk
        header.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        header.appendLittleEndian(UInt32(16))                 // Sub-chunk size (PCM = 16)
        header.appendLittleEndian(UInt16(1))                  // Audio format (PCM = 1)
        header.appendLittleEndian(UInt16(channels))           // Channels
        header.appendLittleEndian(UInt32(sampleRate))         // Sample rate
        header.appendLittleEndian(byteRate)                   // Byte rate
        header.appendLittleEndian(blockAlign)                 // Block align
        header.appendLittleEndian(UInt16(bitsPerSample))      // Bits per sample

        // data sub-chunk
        header.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        header.appendLittleEndian(dataSize)

        assert(header.count == 44, "WAV header must be exactly 44 bytes")

        var wav = header
        wav.append(pcmData)
        return wav
    }

    /// Estimate audio duration from WAV file data.
    ///
    /// - Parameter wavData: Complete WAV file data
    /// - Returns: Duration in seconds
    public static func estimateDuration(from wavData: Data) -> TimeInterval {
        guard wavData.count > 44 else { return 0 }
        let pcmBytes = wavData.count - 44
        return TimeInterval(pcmBytes) / TimeInterval(sampleRate * bytesPerSample)
    }
}

// MARK: - Data Extension for Little-Endian Writing

extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        var le = value.littleEndian
        append(Data(bytes: &le, count: 2))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var le = value.littleEndian
        append(Data(bytes: &le, count: 4))
    }
}
