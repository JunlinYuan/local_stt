import Foundation

/// Volume normalization for WAV audio data.
///
/// Boosts quiet recordings to a target RMS level before sending to Whisper API,
/// improving transcription accuracy for low-volume input. Matches the algorithm
/// in `backend/audio_utils.py:normalize_audio`.
public enum AudioNormalizer {
    public struct Result: Sendable {
        public let wavData: Data
        public let originalRMS: Double
        public let gainDB: Double
        public let processedRMS: Double
    }

    /// Canonical WAV header size. Assumes WAV data is produced by WAVEncoder (no extended chunks).
    private static let wavHeaderSize = 44

    /// Normalize WAV audio to target RMS level.
    /// - Parameters:
    ///   - wavData: Complete WAV file (44-byte header + int16 PCM)
    ///   - targetRMS: Target RMS level (default 3000.0, typical speech for int16)
    ///   - maxGainDB: Maximum gain cap in dB (default 40.0)
    public static func normalize(
        wavData: Data,
        targetRMS: Double = 3000.0,
        maxGainDB: Double = 40.0
    ) -> Result {
        guard wavData.count > wavHeaderSize else {
            return Result(wavData: wavData, originalRMS: 0, gainDB: 0, processedRMS: 0)
        }

        let header = wavData.prefix(wavHeaderSize)
        let pcmData = wavData.suffix(from: wavHeaderSize)
        let sampleCount = pcmData.count / 2

        guard sampleCount > 0 else {
            return Result(wavData: wavData, originalRMS: 0, gainDB: 0, processedRMS: 0)
        }

        // Read int16 samples
        var samples = [Int16](repeating: 0, count: sampleCount)
        pcmData.withUnsafeBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                samples[i] = int16Buffer[i]
            }
        }

        // Calculate current RMS
        var sumSquares: Double = 0
        for sample in samples {
            let s = Double(sample)
            sumSquares += s * s
        }
        let currentRMS = (sumSquares / Double(sampleCount)).squareRoot()

        // Near silence — don't amplify noise
        if currentRMS < 1.0 {
            return Result(wavData: wavData, originalRMS: currentRMS, gainDB: 0, processedRMS: currentRMS)
        }

        // Calculate gain, clamped to [0.1, maxGainLinear]
        var gainLinear = targetRMS / currentRMS
        let maxGainLinear = pow(10.0, maxGainDB / 20.0)
        gainLinear = max(0.1, min(gainLinear, maxGainLinear))

        let gainDB = 20.0 * log10(gainLinear)

        // Apply gain with hard clipping
        var outputSamples = [Int16](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            var amplified = Float(samples[i]) * Float(gainLinear)
            amplified = max(-32768, min(32767, amplified))
            outputSamples[i] = Int16(amplified)
        }

        // Calculate final RMS
        var finalSumSquares: Double = 0
        for sample in outputSamples {
            let s = Double(sample)
            finalSumSquares += s * s
        }
        let processedRMS = (finalSumSquares / Double(sampleCount)).squareRoot()

        // Reassemble WAV
        var outputData = Data(header)
        outputSamples.withUnsafeBytes { rawBuffer in
            outputData.append(contentsOf: rawBuffer)
        }

        return Result(wavData: outputData, originalRMS: currentRMS, gainDB: gainDB, processedRMS: processedRMS)
    }
}
