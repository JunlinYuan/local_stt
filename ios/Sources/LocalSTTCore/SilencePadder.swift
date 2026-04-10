import Foundation

/// Adds silence padding before and after WAV audio data.
///
/// Helps Whisper models (trained on 30-second clips) produce better results
/// on short recordings by reducing edge artifacts. Matches the algorithm
/// in `backend/audio_utils.py:add_silence_padding`.
public enum SilencePadder {
    /// Add silence padding to WAV audio for short clips.
    ///
    /// - Parameters:
    ///   - wavData: Complete WAV file (44-byte header + int16 PCM)
    ///   - maxDuration: Only pad clips shorter than this (seconds). Default 5.0.
    ///   - preSilenceMs: Milliseconds of silence before audio. Default 100.
    ///   - postSilenceMs: Milliseconds of silence after audio. Default 200.
    /// - Returns: Padded WAV data (or original if longer than maxDuration)
    public static func pad(
        wavData: Data,
        maxDuration: TimeInterval = 5.0,
        preSilenceMs: Int = 100,
        postSilenceMs: Int = 200
    ) -> Data {
        let headerSize = 44
        guard wavData.count > headerSize else { return wavData }

        let duration = WAVEncoder.estimateDuration(from: wavData)
        guard duration > 0, duration < maxDuration else { return wavData }

        let preSamples = (preSilenceMs * WAVEncoder.sampleRate) / 1000
        let postSamples = (postSilenceMs * WAVEncoder.sampleRate) / 1000
        let prePadBytes = preSamples * WAVEncoder.bytesPerSample
        let postPadBytes = postSamples * WAVEncoder.bytesPerSample

        let pcmData = wavData.suffix(from: headerSize)
        // Build new PCM: pre-silence + original + post-silence
        var newPCM = Data(count: prePadBytes) // zero-filled = silence
        newPCM.append(pcmData)
        newPCM.append(Data(count: postPadBytes))

        return WAVEncoder.encode(pcmData: newPCM)
    }
}
