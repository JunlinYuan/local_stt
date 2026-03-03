import AVFoundation
import Foundation
import LocalSTTCore

/// Records audio using AVAudioEngine and produces 16kHz mono WAV data.
///
/// Publishes RMS levels for waveform visualization. Handles audio session
/// interruptions (phone calls, lock screen) to avoid stuck recording state.
@Observable
final class AudioRecorder {
    /// Current RMS level (0.0–1.0) for waveform display.
    private(set) var currentRMS: Float = 0

    /// Whether currently recording.
    private(set) var isRecording = false

    private var audioEngine: AVAudioEngine?
    private var pcmBuffers: [Data] = []
    private var interruptionObserver: NSObjectProtocol?

    /// Callback fired when interrupted (e.g., phone call).
    var onInterruption: (() -> Void)?

    init() {
        setupInterruptionHandling()
    }

    deinit {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Recording

    /// Start recording audio. Configures AVAudioSession and installs a tap.
    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true)

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
            throw AudioRecorderError.formatError
        }

        // Create converter from native to 16kHz mono
        guard let converter = AVAudioConverter(from: nativeFormat, to: targetFormat) else {
            throw AudioRecorderError.converterError
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
                // Normalize to 0-1 range (typical speech RMS ~0.01-0.3)
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
                self.pcmBuffers.append(int16Data)
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

        // Combine all PCM buffers
        var pcmData = Data()
        for buffer in pcmBuffers {
            pcmData.append(buffer)
        }
        pcmBuffers = []
        currentRMS = 0

        // Encode as WAV
        return WAVEncoder.encode(pcmData: pcmData)
    }

    /// Cancel recording without producing output.
    func cancel() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isRecording = false
        pcmBuffers = []
        currentRMS = 0
    }

    // MARK: - Interruption Handling

    private func setupInterruptionHandling() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

            switch type {
            case .began:
                // Phone call, Siri, etc. — cancel recording and reset
                if self.isRecording {
                    self.cancel()
                    self.onInterruption?()
                }
            case .ended:
                // Reactivate audio session
                try? AVAudioSession.sharedInstance().setActive(true)
            @unknown default:
                break
            }
        }
    }
}

enum AudioRecorderError: LocalizedError {
    case formatError
    case converterError

    var errorDescription: String? {
        switch self {
        case .formatError: return "Failed to create target audio format."
        case .converterError: return "Failed to create audio converter."
        }
    }
}
