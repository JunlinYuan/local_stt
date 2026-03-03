import Foundation
import LocalSTTCore
#if canImport(UIKit)
import UIKit
#endif

/// Recording lifecycle states.
enum RecordingState: Equatable {
    case ready
    case recording
    case transcribing
    case result(TranscriptionResult)
    case error(String)

    static func == (lhs: RecordingState, rhs: RecordingState) -> Bool {
        switch (lhs, rhs) {
        case (.ready, .ready), (.recording, .recording), (.transcribing, .transcribing):
            return true
        case (.result(let a), .result(let b)):
            return a.id == b.id
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

/// Central app coordinator. Owns services and manages recording lifecycle.
///
/// Uses `@Observable` (iOS 17+) for SwiftUI reactivity. The `recordingDuration`
/// is a separate property (not inside the enum) because @Observable only
/// triggers view updates on direct property assignment.
@Observable
final class AppState {
    // MARK: - State

    var state: RecordingState = .ready
    var recordingDuration: TimeInterval = 0

    // MARK: - Services

    let recorder = AudioRecorder()
    private(set) var vocabularyManager: VocabularyManager
    private var groqService: GroqService?

    // MARK: - Settings (persisted in UserDefaults)

    var language: String {
        didSet { UserDefaults.standard.set(language, forKey: "stt_language") }
    }

    // MARK: - History

    var history: [TranscriptionResult] = []

    private static let maxHistory = 50
    private static let historyKey = "transcription_history"
    private static let keychainAPIKeyKey = "groq_api_key"

    // MARK: - Init

    init() {
        // Load persisted settings
        self.language = UserDefaults.standard.string(forKey: "stt_language") ?? ""

        // Initialize vocabulary manager
        let bundledVocab = Bundle.main.url(forResource: "vocabulary", withExtension: "txt")
        self.vocabularyManager = VocabularyManager(bundledFileURL: bundledVocab)

        // Load API key and create service
        if let apiKey = KeychainHelper.read(key: Self.keychainAPIKeyKey), !apiKey.isEmpty {
            self.groqService = GroqService(apiKey: apiKey)
        }

        // Load history
        self.history = Self.loadHistory()

        // Handle audio interruptions
        recorder.onInterruption = { [weak self] in
            self?.state = .error("Recording interrupted")
            self?.recordingDuration = 0
            self?.scheduleErrorReset()
        }
    }

    // MARK: - API Key Management

    var hasAPIKey: Bool {
        guard let key = KeychainHelper.read(key: Self.keychainAPIKeyKey) else { return false }
        return !key.isEmpty
    }

    func setAPIKey(_ key: String) {
        if key.isEmpty {
            KeychainHelper.delete(key: Self.keychainAPIKeyKey)
            groqService = nil
        } else {
            KeychainHelper.save(key: Self.keychainAPIKeyKey, value: key)
            groqService = GroqService(apiKey: key)
        }
    }

    func getAPIKey() -> String {
        KeychainHelper.read(key: Self.keychainAPIKeyKey) ?? ""
    }

    /// Test if the current API key is valid.
    func testAPIKey() async -> Bool {
        guard let service = groqService else { return false }
        return await service.testConnection()
    }

    // MARK: - Recording Flow

    func startRecording() {
        guard state == .ready || state.isErrorOrResult else { return }

        do {
            try recorder.start()
            state = .recording
            recordingDuration = 0
        } catch {
            state = .error(error.localizedDescription)
            scheduleErrorReset()
        }
    }

    func stopRecordingAndTranscribe() {
        guard state == .recording else { return }

        let wavData = recorder.stop()
        state = .transcribing

        guard let service = groqService else {
            state = .error("Groq API key not configured. Add it in Settings.")
            scheduleErrorReset()
            return
        }

        Task { @MainActor in
            do {
                let prompt = vocabularyManager.buildPrompt()
                let lang = language.isEmpty ? nil : language

                var result = try await service.transcribe(
                    wavData: wavData,
                    language: lang,
                    prompt: prompt
                )

                // Apply vocabulary casing
                let (corrected, _) = vocabularyManager.applyVocabularyCasing(to: result.text)
                if corrected != result.text {
                    result = TranscriptionResult(
                        text: corrected,
                        language: result.language,
                        duration: result.duration,
                        processingTime: result.processingTime,
                        timestamp: result.timestamp
                    )
                }

                // Auto-copy to clipboard
                #if canImport(UIKit)
                UIPasteboard.general.string = result.text
                #endif

                // Add to history
                addToHistory(result)

                state = .result(result)
            } catch {
                state = .error(error.localizedDescription)
                scheduleErrorReset()
            }
        }
    }

    // MARK: - History

    private func addToHistory(_ result: TranscriptionResult) {
        history.insert(result, at: 0)
        if history.count > Self.maxHistory {
            history = Array(history.prefix(Self.maxHistory))
        }
        saveHistory()
    }

    func deleteHistoryItem(_ result: TranscriptionResult) {
        history.removeAll { $0.id == result.id }
        saveHistory()
    }

    func clearHistory() {
        history = []
        saveHistory()
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: Self.historyKey)
        }
    }

    private static func loadHistory() -> [TranscriptionResult] {
        guard let data = UserDefaults.standard.data(forKey: Self.historyKey),
              let history = try? JSONDecoder().decode([TranscriptionResult].self, from: data)
        else { return [] }
        return history
    }

    // MARK: - Error Reset

    private func scheduleErrorReset() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if case .error = state {
                state = .ready
            }
        }
    }
}

// MARK: - State Helpers

extension RecordingState {
    var isErrorOrResult: Bool {
        switch self {
        case .error, .result: return true
        default: return false
        }
    }
}
