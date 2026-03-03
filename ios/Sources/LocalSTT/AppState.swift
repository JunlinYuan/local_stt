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
    case tooShort

    static func == (lhs: RecordingState, rhs: RecordingState) -> Bool {
        switch (lhs, rhs) {
        case (.ready, .ready), (.recording, .recording), (.transcribing, .transcribing),
             (.tooShort, .tooShort):
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
    private(set) var replacementManager: ReplacementManager
    private var groqService: GroqService?

    /// Minimum recording duration — recordings shorter than this are discarded.
    private let minRecordingDuration: TimeInterval = 0.3

    // MARK: - Settings (persisted in UserDefaults)

    var language: String {
        didSet { UserDefaults.standard.set(language, forKey: "stt_language") }
    }

    // MARK: - Observable Mirrors
    //
    // VocabularyManager and ReplacementManager are not @Observable. SwiftUI only
    // tracks direct stored properties on @Observable classes, so we mirror
    // frequently-changing values here. Use syncVocabulary() / syncReplacements()
    // after any mutation.

    /// Mirrored from VocabularyManager for SwiftUI reactivity.
    var vocabularyWords: [String] = []
    var vocabularyUsageCounts: [String: Int] = [:]

    /// Mirrored from ReplacementManager for SwiftUI reactivity.
    var replacementRules: [ReplacementRule] = []
    var replacementsEnabled: Bool = true

    // MARK: - History

    var history: [TranscriptionResult] = []

    private static let maxHistory = 100
    private static let historyKey = "transcription_history"
    private static let keychainAPIKeyKey = "groq_api_key"

    // MARK: - Init

    init() {
        // Load persisted settings
        self.language = UserDefaults.standard.string(forKey: "stt_language") ?? ""

        // Initialize vocabulary manager
        let bundledVocab = Bundle.main.url(forResource: "vocabulary", withExtension: "txt")
        let bundledUsage = Bundle.main.url(forResource: "vocabulary_usage", withExtension: "json")
        self.vocabularyManager = VocabularyManager(bundledFileURL: bundledVocab, bundledUsageURL: bundledUsage)

        // Initialize replacement manager
        let bundledReplacements = Bundle.main.url(forResource: "replacements", withExtension: "json")
        self.replacementManager = ReplacementManager(bundledFileURL: bundledReplacements)

        // Load API key and create service
        if let apiKey = KeychainHelper.read(key: Self.keychainAPIKeyKey), !apiKey.isEmpty {
            self.groqService = GroqService(apiKey: apiKey)
        }

        // Load history
        self.history = Self.loadHistory()

        // Sync observable mirrors for SwiftUI
        self.vocabularyWords = vocabularyManager.words
        self.vocabularyUsageCounts = vocabularyManager.usageCounts
        self.replacementRules = replacementManager.rules
        self.replacementsEnabled = replacementManager.isEnabled

        // Normalize unknown language codes (e.g. persisted "ja" from removed button)
        let knownCodes = ["", "en", "fr", "zh"]
        if !knownCodes.contains(language) { language = "" }

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

        // Set state FIRST for instant visual feedback — audio setup can take
        // 50-100ms (AVAudioSession category + activation + engine start).
        state = .recording
        recordingDuration = 0

        do {
            try recorder.start()
        } catch {
            state = .error(error.localizedDescription)
            scheduleErrorReset()
        }
    }

    func stopRecordingAndTranscribe() {
        guard state == .recording else { return }

        // Guard: if recorder never successfully started, don't attempt stop/transcribe
        guard recorder.isRecording else {
            state = .ready
            return
        }

        let wavData = recorder.stop()
        state = .transcribing

        // Check API key first (more actionable error than "too short")
        guard let service = groqService else {
            state = .error("Groq API key not configured. Add it in Settings.")
            scheduleErrorReset()
            return
        }

        // Check minimum duration
        if WAVEncoder.estimateDuration(from: wavData) < minRecordingDuration {
            state = .tooShort
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

                // Pipeline: vocab casing → record usage → replacements → hallucination check

                // 1. Apply vocabulary casing
                let (corrected, matchedWords) = vocabularyManager.applyVocabularyCasing(to: result.text)
                var finalText = corrected

                // 2. Record vocabulary usage
                vocabularyManager.recordUsage(for: matchedWords)
                syncVocabulary()

                // 3. Apply word replacements (if enabled)
                finalText = replacementManager.applyReplacements(to: finalText)

                // 4. Check for hallucination
                if HallucinationFilter.isHallucination(finalText) {
                    state = .error("Discarded (hallucination detected)")
                    scheduleErrorReset()
                    return
                }

                // 5. Append trailing space for seamless paste-to-continue
                if !finalText.hasSuffix(" ") {
                    finalText += " "
                }

                // Build final result if text was modified
                if finalText != result.text {
                    result = TranscriptionResult(
                        text: finalText,
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
        let snapshot = history
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: Self.historyKey)
            }
        }
    }

    private static func loadHistory() -> [TranscriptionResult] {
        guard let data = UserDefaults.standard.data(forKey: Self.historyKey),
              let history = try? JSONDecoder().decode([TranscriptionResult].self, from: data)
        else { return [] }
        return history
    }

    // MARK: - Observable Sync

    /// Sync vocabulary mirrors after any VocabularyManager mutation.
    func syncVocabulary() {
        vocabularyWords = vocabularyManager.words
        vocabularyUsageCounts = vocabularyManager.usageCounts
    }

    /// Sync replacement mirrors after any ReplacementManager mutation.
    func syncReplacements() {
        replacementRules = replacementManager.rules
        replacementsEnabled = replacementManager.isEnabled
    }

    // MARK: - Error Reset

    private func scheduleErrorReset() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if case .error = state {
                state = .ready
            } else if case .tooShort = state {
                state = .ready
            }
        }
    }
}

// MARK: - State Helpers

extension RecordingState {
    var isErrorOrResult: Bool {
        switch self {
        case .error, .result, .tooShort: return true
        default: return false
        }
    }
}
