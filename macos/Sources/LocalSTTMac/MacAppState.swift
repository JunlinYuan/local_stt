import AppKit
import ApplicationServices
import Foundation
import LocalSTTCore
import OSLog

private let logger = Logger(subsystem: "com.localSTT.mac", category: "AppState")

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

    var isErrorOrResult: Bool {
        switch self {
        case .error, .result, .tooShort: return true
        default: return false
        }
    }

    var isRecordingOrTranscribing: Bool {
        switch self {
        case .recording, .transcribing: return true
        default: return false
        }
    }
}

/// Central Mac app coordinator. Owns services and manages recording lifecycle.
///
/// Separate from iOS AppState — uses NSPasteboard, owns MacAudioRecorder,
/// GlobalHotkeyManager, and AutoPasteManager.
@Observable
final class MacAppState {
    // MARK: - State

    var state: RecordingState = .ready
    var recordingDuration: TimeInterval = 0
    var accessibilityGranted: Bool = false

    // MARK: - Services

    let recorder = MacAudioRecorder()
    private(set) var vocabularyManager: VocabularyManager
    private(set) var replacementManager: ReplacementManager
    private var groqService: GroqService?
    private(set) var hotkeyManager: GlobalHotkeyManager?
    private(set) var autoPasteManager: AutoPasteManager?

    private let minRecordingDuration: TimeInterval = 0.3
    private let minVolumeRMS: Double = 100.0

    // MARK: - Settings (persisted in UserDefaults)

    var language: String {
        didSet { UserDefaults.standard.set(language, forKey: "stt_language") }
    }

    var ffmEnabled: Bool {
        didSet { UserDefaults.standard.set(ffmEnabled, forKey: "ffm_enabled") }
    }

    var ffmMode: String {
        didSet { UserDefaults.standard.set(ffmMode, forKey: "ffm_mode") }
    }

    var clipboardSyncDelay: Double {
        didSet { UserDefaults.standard.set(clipboardSyncDelay, forKey: "clipboard_sync_delay") }
    }

    var pasteDelay: Double {
        didSet { UserDefaults.standard.set(pasteDelay, forKey: "paste_delay") }
    }

    var volumeNormalization: Bool {
        didSet { UserDefaults.standard.set(volumeNormalization, forKey: "volume_normalization") }
    }

    var saveDebugAudio: Bool {
        didSet { UserDefaults.standard.set(saveDebugAudio, forKey: "save_debug_audio") }
    }

    // MARK: - Observable Mirrors

    var vocabularyWords: [String] = []
    var vocabularyUsageCounts: [String: Int] = [:]
    var replacementRules: [ReplacementRule] = []
    var replacementsEnabled: Bool = true

    // MARK: - Transient State

    var lastNormalizationGainDB: Double? = nil

    // MARK: - History

    var history: [TranscriptionResult] = []

    private static let maxHistory = 100
    private static let historyKey = "transcription_history"
    private static let keychainAPIKeyKey = "groq_api_key"

    // MARK: - Init

    init() {
        // Load persisted settings
        self.language = UserDefaults.standard.string(forKey: "stt_language") ?? ""
        self.ffmEnabled = UserDefaults.standard.object(forKey: "ffm_enabled") as? Bool ?? true
        self.ffmMode = UserDefaults.standard.string(forKey: "ffm_mode") ?? "track_only"
        self.clipboardSyncDelay = UserDefaults.standard.object(forKey: "clipboard_sync_delay") as? Double ?? 0.05
        self.pasteDelay = UserDefaults.standard.object(forKey: "paste_delay") as? Double ?? 0.05
        self.volumeNormalization = UserDefaults.standard.object(forKey: "volume_normalization") as? Bool ?? true
        self.saveDebugAudio = UserDefaults.standard.object(forKey: "save_debug_audio") as? Bool ?? false

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

        // Sync observable mirrors
        self.vocabularyWords = vocabularyManager.words
        self.vocabularyUsageCounts = vocabularyManager.usageCounts
        self.replacementRules = replacementManager.rules
        self.replacementsEnabled = replacementManager.isEnabled

        // Normalize unknown language codes
        let knownCodes = ["", "en", "fr", "zh", "ja"]
        if !knownCodes.contains(language) { language = "" }
    }

    // MARK: - Service Setup (called after init, needs self reference)

    private var isSetUp = false

    func setupServices() {
        guard !isSetUp else { return }
        isSetUp = true

        // Check and prompt for Accessibility permission (required for global hotkey + FFM)
        checkAccessibilityPermission()

        // Global hotkey: Left Control hold-to-record
        // Ctrl+<key> cancels recording (user is doing a keyboard shortcut, not recording)
        hotkeyManager = GlobalHotkeyManager(
            onPress: { [weak self] in
                DispatchQueue.main.async { self?.startRecording() }
            },
            onRelease: { [weak self] in
                DispatchQueue.main.async { self?.stopRecordingAndTranscribe() }
            },
            onCancel: { [weak self] in
                DispatchQueue.main.async { self?.cancelRecording() }
            }
        )

        // Auto-paste manager for FFM
        autoPasteManager = AutoPasteManager()
        autoPasteManager?.isEnabled = ffmEnabled
        autoPasteManager?.mode = ffmMode == "raise_on_hover" ? .raiseOnHover : .trackOnly
    }

    /// Check Accessibility permission and prompt if not granted.
    /// Sets `accessibilityGranted` and logs the result.
    func checkAccessibilityPermission() {
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        )
        accessibilityGranted = trusted
        if trusted {
            logger.info("Accessibility permission: granted")
        } else {
            logger.warning("Accessibility permission: NOT granted — FFM and global hotkey will not work fully")
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

    func testAPIKey() async -> Bool {
        guard let service = groqService else { return false }
        return await service.testConnection()
    }

    // MARK: - Recording Flow

    func startRecording() {
        guard state == .ready || state.isErrorOrResult else { return }

        state = .recording
        recordingDuration = 0

        do {
            try recorder.start()
        } catch {
            state = .error(error.localizedDescription)
            scheduleErrorReset()
        }
    }

    func cancelRecording() {
        guard state == .recording else { return }
        _ = recorder.stop()  // Discard audio
        state = .ready
        logger.info("Recording cancelled (Ctrl+key shortcut detected)")
    }

    func stopRecordingAndTranscribe() {
        guard state == .recording else { return }

        guard recorder.isRecording else {
            state = .ready
            return
        }

        let rawWavData = recorder.stop()
        state = .transcribing

        guard let service = groqService else {
            state = .error("Groq API key not configured. Add it in Settings.")
            scheduleErrorReset()
            return
        }

        if WAVEncoder.estimateDuration(from: rawWavData) < minRecordingDuration {
            state = .tooShort
            scheduleErrorReset()
            return
        }

        // Normalize volume if enabled
        var wavData = rawWavData
        var normGainDB: Double? = nil
        var processedRMS: Double
        if volumeNormalization {
            let normResult = AudioNormalizer.normalize(wavData: rawWavData)
            wavData = normResult.wavData
            normGainDB = abs(normResult.gainDB) >= 1.0 ? normResult.gainDB : nil
            processedRMS = normResult.processedRMS
            logger.info("Volume normalization: RMS \(normResult.originalRMS, format: .fixed(precision: 0)) → \(normResult.processedRMS, format: .fixed(precision: 0)), gain \(normResult.gainDB, format: .fixed(precision: 1))dB")
        } else {
            processedRMS = AudioNormalizer.calculateRMS(wavData: rawWavData)
        }
        lastNormalizationGainDB = normGainDB

        // Min volume check (always runs, matching backend)
        if processedRMS < minVolumeRMS {
            saveDebugAudioFiles(raw: rawWavData, processed: wavData)
            state = .error("Too quiet — no speech detected")
            scheduleErrorReset()
            return
        }

        // Silence padding for short clips (improves Whisper accuracy)
        wavData = SilencePadder.pad(wavData: wavData)

        // Save debug audio files to Desktop
        saveDebugAudioFiles(raw: rawWavData, processed: wavData)

        Task { @MainActor in
            do {
                let prompt = vocabularyManager.buildPrompt()
                let lang = language.isEmpty ? nil : language

                var result = try await service.transcribe(
                    wavData: wavData,
                    language: lang,
                    prompt: prompt
                )

                // Pipeline: vocab casing -> record usage -> replacements -> hallucination check

                let (corrected, matchedWords) = vocabularyManager.applyVocabularyCasing(to: result.text)
                var finalText = corrected

                vocabularyManager.recordUsage(for: matchedWords)
                syncVocabulary()

                finalText = replacementManager.applyReplacements(to: finalText)

                if HallucinationFilter.isHallucination(finalText) {
                    state = .error("Discarded (hallucination detected)")
                    scheduleErrorReset()
                    return
                }

                if !finalText.hasSuffix(" ") {
                    finalText += " "
                }

                if finalText != result.text || normGainDB != nil {
                    result = TranscriptionResult(
                        text: finalText,
                        language: result.language,
                        duration: result.duration,
                        processingTime: result.processingTime,
                        timestamp: result.timestamp,
                        gainDB: normGainDB
                    )
                }

                // Add to history
                addToHistory(result)

                state = .result(result)

                // Auto-paste to window under cursor (if FFM enabled)
                if ffmEnabled, let pasteManager = autoPasteManager {
                    logger.info("Auto-paste: ffmEnabled=\(self.ffmEnabled), trackedPID=\(pasteManager.trackedPID), trackedApp=\(pasteManager.trackedAppName, privacy: .public)")
                    pasteManager.pasteText(
                        result.text,
                        clipboardDelay: clipboardSyncDelay,
                        pasteDelay: pasteDelay
                    )
                } else {
                    logger.info("No auto-paste: ffmEnabled=\(self.ffmEnabled), autoPasteManager=\(self.autoPasteManager != nil)")
                    // Just copy to clipboard
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.text, forType: .string)
                }
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

    func syncVocabulary() {
        vocabularyWords = vocabularyManager.words
        vocabularyUsageCounts = vocabularyManager.usageCounts
    }

    func syncReplacements() {
        replacementRules = replacementManager.rules
        replacementsEnabled = replacementManager.isEnabled
    }

    // MARK: - FFM Settings Sync

    func updateFFMSettings() {
        autoPasteManager?.isEnabled = ffmEnabled
        autoPasteManager?.mode = ffmMode == "raise_on_hover" ? .raiseOnHover : .trackOnly
    }

    /// Recreate all global event monitors after Accessibility permission is granted.
    /// Call this after the user grants permission in System Settings.
    func restartMonitors() {
        // Refresh permission state (no prompt — user just came back from System Settings)
        accessibilityGranted = AXIsProcessTrusted()
        hotkeyManager?.restartMonitoring()
        autoPasteManager?.restartTracking()
    }

    // MARK: - Bulk Export / Import

    /// JSON structure for bulk export/import of vocabulary and replacement data.
    private struct BulkData: Codable {
        var vocabulary: [String]?
        var replacements: [BulkReplacement]?

        struct BulkReplacement: Codable {
            let from: String
            let to: String
        }
    }

    /// Export vocabulary words and replacement rules as JSON data.
    func exportBulkData() -> Data? {
        let bulk = BulkData(
            vocabulary: vocabularyManager.words,
            replacements: replacementManager.rules.map {
                BulkData.BulkReplacement(from: $0.from, to: $0.to)
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(bulk)
    }

    /// Import vocabulary words and replacement rules from JSON data.
    /// Returns a summary string describing what was imported.
    func importBulkData(_ data: Data) -> String {
        guard let bulk = try? JSONDecoder().decode(BulkData.self, from: data) else {
            return "Invalid JSON format"
        }

        var parts: [String] = []

        if let words = bulk.vocabulary {
            vocabularyManager.setWords(words)
            syncVocabulary()
            parts.append("\(vocabularyManager.words.count) vocabulary words")
        }

        if let replacements = bulk.replacements {
            // Snapshot for rollback on total failure
            let existingRules = replacementManager.rules
            for rule in existingRules {
                _ = replacementManager.removeRule(rule)
            }
            // Add imported rules
            var added = 0
            for r in replacements {
                let (success, _) = replacementManager.addRule(from: r.from, to: r.to)
                if success { added += 1 }
            }
            if added == 0 && !replacements.isEmpty {
                // Rollback: restore original rules
                for rule in existingRules {
                    _ = replacementManager.addRule(from: rule.from, to: rule.to)
                }
                syncReplacements()
                parts.append("0 replacement rules (all failed validation, originals restored)")
            } else {
                syncReplacements()
                parts.append("\(added) replacement rules")
            }
        }

        return parts.isEmpty ? "No data found in file" : "Imported \(parts.joined(separator: " and "))"
    }

    // MARK: - Error Reset

    private func saveDebugAudioFiles(raw rawWavData: Data, processed wavData: Data) {
        guard saveDebugAudio else { return }
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let rawURL = desktop.appendingPathComponent("debug_raw_\(timestamp).wav")
        let processedURL = desktop.appendingPathComponent("debug_processed_\(timestamp).wav")
        do {
            try rawWavData.write(to: rawURL)
            try wavData.write(to: processedURL)
            logger.info("Debug audio saved: \(rawURL.lastPathComponent) (\(rawWavData.count) bytes), \(processedURL.lastPathComponent) (\(wavData.count) bytes)")
        } catch {
            logger.error("Failed to save debug audio: \(error.localizedDescription)")
        }
    }

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
