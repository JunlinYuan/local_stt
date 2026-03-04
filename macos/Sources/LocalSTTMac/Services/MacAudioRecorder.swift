import AVFoundation
import Foundation
import LocalSTTCore

/// Records audio using AVAudioEngine and produces 16kHz mono WAV data.
///
/// macOS version — no AVAudioSession (iOS-only). Just creates AVAudioEngine,
/// installs a tap, and starts. Publishes RMS levels for waveform visualization.
@Observable
final class MacAudioRecorder {
    /// Current RMS level (0.0–1.0) for waveform display.
    private(set) var currentRMS: Float = 0

    /// Whether currently recording.
    private(set) var isRecording = false

    private var audioEngine: AVAudioEngine?
    private var pcmBuffers: [Data] = []
    private let bufferLock = NSLock()

    // MARK: - Recording

    /// Start recording audio. On macOS, no session setup needed — just start the engine.
    func start() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        pcmBuffers = []
        currentRMS = 0

        // Target format: 16kHz mono Float32 (for conversion)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(WAVEncoder.sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw MacAudioRecorderError.formatError
        }

        // Create converter from native to 16kHz mono
        guard let converter = AVAudioConverter(from: nativeFormat, to: targetFormat) else {
            throw MacAudioRecorderError.converterError
        }

        let bufferSize: AVAudioFrameCount = 4096

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: nativeFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // Convert to 16kHz mono
            let frameCapacity = AVAudioFrameCount(
                Double(buffer.frameLength) * Double(WAVEncoder.sampleRate) / nativeFormat.sampleRate
            )
            guard frameCapacity > 0 else { return }

            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: frameCapacity
            ) else { return }

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            guard status != .error, error == nil else { return }

            // Calculate RMS from the converted buffer
            if let channelData = convertedBuffer.floatChannelData {
                let frames = Int(convertedBuffer.frameLength)
                var sum: Float = 0
                for i in 0..<frames {
                    let sample = channelData[0][i]
                    sum += sample * sample
                }
                let rms = sqrt(sum / max(Float(frames), 1))
                let normalized = min(rms * 5, 1.0)

                DispatchQueue.main.async {
                    self.currentRMS = normalized
                }
            }

            // Convert Float32 to Int16 PCM for WAV encoding
            if let channelData = convertedBuffer.floatChannelData {
                let frames = Int(convertedBuffer.frameLength)
                var int16Data = Data(capacity: frames * 2)
                for i in 0..<frames {
                    let clamped = max(-1.0, min(1.0, channelData[0][i]))
                    var sample = Int16(clamped * Float(Int16.max))
                    int16Data.append(Data(bytes: &sample, count: 2))
                }
                self.bufferLock.lock()
                self.pcmBuffers.append(int16Data)
                self.bufferLock.unlock()
            }
        }

        try engine.start()
        audioEngine = engine
        isRecording = true
    }

    /// Stop recording and return WAV data.
    func stop() -> Data {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isRecording = false

        bufferLock.lock()
        let snapshot = pcmBuffers
        pcmBuffers = []
        bufferLock.unlock()

        var pcmData = Data()
        for buffer in snapshot {
            pcmData.append(buffer)
        }
        currentRMS = 0

        return WAVEncoder.encode(pcmData: pcmData)
    }

    /// Cancel recording without producing output.
    func cancel() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isRecording = false
        bufferLock.lock()
        pcmBuffers = []
        bufferLock.unlock()
        currentRMS = 0
    }
}

enum MacAudioRecorderError: LocalizedError {
    case formatError
    case converterError

    var errorDescription: String? {
        switch self {
        case .formatError: return "Failed to create target audio format."
        case .converterError: return "Failed to create audio converter."
        }
    }
}
