# iOS Swift App Analysis Report
**Local STT iOS Implementation**
**Date**: 2026-03-02
**Repository**: https://github.com/JunlinYuan/local_stt
**Target**: iOS 17+ (macOS 14+ also declared in Package.swift but not implemented)

---

## Executive Summary

The Local STT iOS app is a fully-featured speech-to-text client built with **SwiftUI** and **AVAudioEngine**, using **Groq's Whisper API** for transcription. The architecture cleanly separates business logic (LocalSTTCore package) from UI, implements sophisticated text processing (vocabulary casing, regex replacements, hallucination filtering), and provides a polished UX with hold-to-record, real-time waveform visualization, and inline transcription history.

**Key Strengths**:
- Modular, testable core library (LocalSTTCore)
- Comprehensive text processing pipeline with usage tracking
- Reliable audio recording (AVAudioEngine with interruption handling)
- Polished SwiftUI UI with dark theme, responsive states, accessibility
- Thread-safe vocabulary/replacement managers using NSLock
- Secure API key storage (Keychain)

---

## 1. Feature Inventory

### User-Facing Features

#### 1.1 Push-to-Talk Recording
- **Hold-to-record button** (120px tall, full-width rounded rectangle)
- **Real-time waveform visualization** (40 animated bars, RMS-based)
- **Recording duration display** (M:SS format, updated 1Hz)
- **Instant visual feedback**: Red border pulse, color state changes
- **Interruption handling**: Auto-cancel on phone calls, Siri, lock screen
- **Minimum duration filter**: Skips accidental short taps (0.3s threshold)

**Implementation Details**:
- RecordButton.swift uses UILongPressGestureRecognizer (SwiftUI DragGesture unreliable)
- HoldGestureView: UIViewRepresentable bridging UIKit gesture
- WaveformView: Consumes AudioRecorder.currentRMS, adds jitter for visual interest
- AppState.recordingDuration synced to UI every 1 second

#### 1.2 Transcription Results
- **Auto-paste to clipboard** (immediately on completion, with trailing space)
- **Status feedback**: "Copied to clipboard" (teal color), error messages, "too short" warning
- **Result display**: Text with metadata (language badge, duration, processing time)
- **Copy button in history**: Tap any result to copy, 1s "Copied" flash

**Implementation Details**:
- UIPasteboard.general.string set in AppState.stopRecordingAndTranscribe()
- ResultCard component with copy button + state management
- HistoryListView highlights latest result, scrolls to top

#### 1.3 Transcription History
- **Inline history on main screen** (compact cards above record button)
- **Full history sheet** (swipe-to-delete via List)
- **Search functionality** (case-insensitive, highlights matches in teal)
- **Metadata display**: Language badge, duration, relative timestamp ("2m ago")
- **Maximum 100 results** (persisted in UserDefaults)

**Implementation Details**:
- HistoryListView: Reusable in compact (ScrollView + custom cards) and full (List) modes
- Search text highlighting: Custom Text construction with substring ranges
- Delete: AppState.deleteHistoryItem() removes by id
- Clear All: Destructive button in TranscriptionHistoryView toolbar

#### 1.4 Language Selection
- **One-tap language bar** (4 capsule buttons: AUTO, EN, FR, 中文)
- **Instant switching** during recording/before recording
- **Persisted in UserDefaults** (key: "stt_language")
- **Fallback**: Unknown codes (e.g. persisted "ja") treated as AUTO

**Implementation Details**:
- LanguageBar.swift: Simple binding to Binding<String>
- Options: "" (auto), "en", "fr", "zh" (passed to Groq API)
- UI normalization: AppState validates at init, resets invalid codes

#### 1.5 Vocabulary Management (Custom Words)
- **Add/remove words** with inline UI panel
- **Usage tracking badges** (×N format, e.g. "×47")
- **Words ordered by usage** (most-used first in file + panel display)
- **Maximum 85 words** (hard limit, Groq API constraint)
- **Syntax highlighting in transcriptions** (canonical case applied)

**Implementation Details**:
- VocabularyPanelView: TextField + add button, deletion with trash icon
- VocabularyManager stores words in Application Support/LocalSTT/vocabulary.txt
- File format: Plain text, one word per line, comments start with #
- Bundled vocabulary copies on first launch
- Usage counts in vocabulary_usage.json (Key: word, Value: Int count)
- recordUsage() increments counters, saveToFile() reorders by usage
- applyVocabularyCasing() uses word-boundary regex (\\bword\\b, case-insensitive)

#### 1.6 Text Replacements (Find/Replace Rules)
- **Add/remove replacement rules** with UI panel
- **From → To display** with arrow visualization
- **Enable/disable all replacements** with toggle (persisted)
- **Maximum 100 rules** (hard limit)
- **Case-insensitive matching** with whole-word boundaries

**Implementation Details**:
- ReplacementPanelView: Two-field form (from, to) with arrow icon
- ReplacementManager stores in replacements.json: {replacements: [{from, to}, ...]}
- File format: JSON with pretty-printing
- Rules applied in order (sequential processing via zip)
- Pre-compiled NSRegularExpression patterns stored for performance
- Replacement template escaping: $, \, & → \$, \\, \& (prevent NSRegularExpression interpretation)

#### 1.7 Hallucination Filtering
- **Auto-discard phantom transcriptions** from silent/quiet audio
- **Always on** (no toggle)
- **Error state**: "Discarded (hallucination detected)" → 3s auto-reset
- **Multilingual**: 50+ known phrases (English, Chinese, Japanese, French)

**Implementation Details**:
- HallucinationFilter static enum with Set<String> phrases
- Filters entire transcription only—partial matches ignored
- Normalization: trim, lowercase, U+2019 (') → U+0027 (')
- Examples: "thank you", "thanks", "subscribe", "bye", "謝謝", "ありがとう", "merci"

#### 1.8 API Key Management
- **Secure Keychain storage** (kSecAttrAccessibleWhenUnlocked)
- **SecureField in UI** (hide/show toggle)
- **Test button** (validates API key, 3s feedback with ✓/✗)
- **Settings sheet** (gear icon in navigation)

**Implementation Details**:
- KeychainHelper static enum (Service: "com.localSTT.app")
- Save/read/delete operations with CFDictionary
- SettingsView: Form with SecureField, eye toggle, Test button
- testAPIKey() creates temporary GroqService, calls testConnection() (sends silent WAV)

---

## 2. Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                        LocalSTTApp.swift                        │
│                      (Entry point, @main)                       │
│                        ↓ WindowGroup                            │
└─────────────────────────┬───────────────────────────────────────┘
                          │
                          ↓
         ┌────────────────────────────────────┐
         │      RecordingView (Main UI)       │
         │  - Navigation, state dispatch      │
         │  - Sheet management (Settings,     │
         │    Vocabulary, Replacements)       │
         └────────────────┬───────────────────┘
                          │
                          ↓
         ┌────────────────────────────────────┐
         │    @Environment AppState           │
         │  (Central State Coordinator)       │
         ├────────────────────────────────────┤
         │ Properties:                        │
         │ • state: RecordingState            │
         │ • recordingDuration: TimeInterval  │
         │ • history: [TranscriptionResult]   │
         │ • language: String (UserDefaults)  │
         │                                    │
         │ Observable Mirrors (for UI):       │
         │ • vocabularyWords: [String]        │
         │ • vocabularyUsageCounts: Dict      │
         │ • replacementRules: [Rule]         │
         │ • replacementsEnabled: Bool        │
         ├────────────────────────────────────┤
         │ Services Owned:                    │
         │ • recorder: AudioRecorder          │
         │ • vocabularyManager: Vocabulary    │
         │ • replacementManager: Replacement  │
         │ • groqService: GroqService?        │
         │ • keychain: API key storage        │
         └────────┬──────────────┬────────────┘
                  │              │
        ┌─────────▼──┐    ┌──────▼──────────┐
        │AudioRecorder│    │LocalSTTCore    │
        │ (AVAudio    │    │Services        │
        │  Engine)    │    │                │
        │ ↓RMS levels │    │ • GroqService  │
        │ ↓PCM buffers│    │ • VocabularyMgr│
        └─────────────┘    │ • ReplacementMg│
                           │ • HallucinFilter│
                           │ • WAVEncoder   │
                           │ • KeychainHelper│
                           └─────┬──────────┘
                                 │
                        ┌────────▼────────┐
                        │Groq Whisper API │
                        │https://api.groq │
                        │.com/openai/v1   │
                        │/audio/trans     │
                        └─────────────────┘
```

### Data Flow (Recording → Transcription)

```
1. User Holds Button
   └─→ AppState.startRecording()
       └─→ AudioRecorder.start()
           └─→ AVAudioEngine tap + format conversion
               └─→ Publishes currentRMS → WaveformView animates

2. User Releases Button
   └─→ AppState.stopRecordingAndTranscribe()
       └─→ AudioRecorder.stop()
           └─→ WAVEncoder.encode() [16kHz mono PCM + 44-byte RIFF]
           └─→ GroqService.transcribe(wavData, language, prompt)
               ├─→ VocabularyManager.buildPrompt()
               ├─→ Multipart POST to Groq API
               └─→ Returns TranscriptionResult

3. Post-Processing Pipeline
   ├─→ applyVocabularyCasing() [whole-word regex, case-insensitive]
   ├─→ recordUsage() [increment counters, save JSON]
   ├─→ applyReplacements() [sequential rule application]
   ├─→ HallucinationFilter.isHallucination() [exact match check]
   ├─→ Auto-paste to clipboard [UIPasteboard.general.string]
   └─→ addToHistory() [UserDefaults persisted]

4. UI Update
   └─→ state = .result(TranscriptionResult)
       └─→ RecordingView reflects change
           └─→ Status message, highlight in history, copy button
```

---

## 3. Data Models

### TranscriptionResult.swift
**Location**: `/Users/junlin/Documents/GitHub/local_stt/ios/Sources/LocalSTTCore/TranscriptionResult.swift`

```swift
public struct TranscriptionResult: Identifiable, Codable, Sendable {
    public let id: UUID
    public let text: String
    public let language: String
    public let duration: TimeInterval
    public let processingTime: TimeInterval
    public let timestamp: Date

    // Computed properties for UI
    public var formattedDuration: String  // "0.5s" or "1:23"
    public var formattedProcessingTime: String  // "0.8s"
    public var relativeTimestamp: String  // "2m ago"
}
```

**Usage**:
- Stored in history (UserDefaults as JSON)
- Displayed in HistoryListView, ResultCard
- Copied to clipboard with text + trailing space

### ReplacementRule.swift
**Location**: `/Users/junlin/Documents/GitHub/local_stt/ios/Sources/LocalSTTCore/ReplacementRule.swift`

```swift
public struct ReplacementRule: Identifiable, Codable, Sendable {
    public let id: UUID
    public let from: String
    public let to: String

    // Custom Codable: id synthesized if missing in JSON (for backward compat)
    // File format in replacements.json: {replacements: [{from, to}, ...]}
}
```

**Key Details**:
- Custom Decodable: id defaults to UUID() if absent (line 22)
- Used in ReplacementManager.applyReplacements()
- Displayed in ReplacementPanelView with deletion

### RecordingState.swift
**Location**: `/Users/junlin/Documents/GitHub/local_stt/ios/Sources/LocalSTT/AppState.swift` (lines 8-29)

```swift
enum RecordingState: Equatable {
    case ready
    case recording
    case transcribing
    case result(TranscriptionResult)
    case error(String)
    case tooShort

    // Custom == for result(.id comparison) and error(String comparison)
}
```

**UI Implications**:
- `.recording`: Red border pulse, duration timer active, "STOP" state
- `.transcribing`: Amber color, ProgressView spinner
- `.result`: Teal checkmark, "Copied to clipboard" message
- `.error`: Red message display, 3s auto-reset
- `.tooShort`: Amber message, 3s auto-reset
- `.ready`: Default state (teal accent button)

---

## 4. Audio Pipeline (Detailed)

### AVAudioEngine Recording Flow
**File**: `/Users/junlin/Documents/GitHub/local_stt/ios/Sources/LocalSTT/Services/AudioRecorder.swift`

#### Setup Phase (AudioRecorder.start())
1. **Audio Session Configuration**
   ```swift
   try session.setCategory(.record, mode: .measurement, options: [])
   try session.setActive(true)
   ```
   - Category: `.record` (minimizes system sounds, ignores ringer switch)
   - Mode: `.measurement` (maximizes audio input fidelity)

2. **AVAudioEngine Format Configuration**
   - Input node native format (device-dependent, usually 48kHz or 44.1kHz)
   - Target format: 16kHz, mono, Float32 (for conversion)
   - AVAudioConverter: Native → target (handles resampling)

3. **Buffer Tap Installation**
   - Buffer size: 4096 frames
   - Format: Native (before conversion)
   - Callback fires ~24Hz (4096 samples / 48kHz ≈ 85ms intervals)

#### Processing Callback (Per 4096-frame buffer)
1. **Audio Conversion**: Native → 16kHz mono Float32
2. **RMS Calculation** (for waveform visualization)
   ```swift
   var sum: Float = 0
   for i in 0..<frames {
       let sample = channelData[0][i]
       sum += sample * sample
   }
   let rms = sqrt(sum / max(Float(frames), 1))
   let normalized = min(rms * 5, 1.0)  // Clamp to 0-1
   ```
   - Normalization multiplier: ×5 (typical speech RMS 0.01-0.3, needs boost)
   - Published to @Observable property → WaveformView updates

3. **Int16 PCM Conversion** (for WAV encoding)
   ```swift
   let clamped = max(-1.0, min(1.0, sample))
   var sample = Int16(clamped * Float(Int16.max))  // -32768 to 32767
   int16Data.append(Data(bytes: &sample, count: 2))
   ```
   - Clamps Float32 to [-1.0, 1.0] to prevent overflow
   - Little-endian Int16 samples (WAV standard)

4. **Buffer Accumulation**
   - Append Int16 data to pcmBuffers array
   - Post RMS update on main thread

#### Stop & Encoding (AudioRecorder.stop())
1. **Remove tap + Stop engine**
   - audioEngine?.inputNode.removeTap(onBus: 0)
   - audioEngine?.stop()

2. **Combine PCM buffers**
   ```swift
   var pcmData = Data()
   for buffer in pcmBuffers {
       pcmData.append(buffer)
   }
   ```

3. **WAV Encoding** (WAVEncoder.encode())

### WAV Encoding Details
**File**: `/Users/junlin/Documents/GitHub/local_stt/ios/Sources/LocalSTTCore/WAVEncoder.swift`

#### RIFF Header (44 bytes, standard format)
```
0x00-0x03: "RIFF" (0x52494646)
0x04-0x07: file_size - 8 (Little-endian UInt32)
0x08-0x0B: "WAVE" (0x57415645)

0x0C-0x0F: "fmt " (0x666D7420)
0x10-0x13: 16 (PCM subchunk size)
0x14-0x15: 1 (Audio format = PCM)
0x16-0x17: 1 (Channels = mono)
0x18-0x1B: 16000 (Sample rate)
0x1C-0x1F: 32000 (Byte rate = 16000 * 1 * 2)
0x20-0x21: 2 (Block align = 1 * 2)
0x22-0x23: 16 (Bits per sample)

0x24-0x27: "data" (0x64617461)
0x28-0x2B: pcm_size (Little-endian UInt32)

0x2C onwards: PCM data (Int16 little-endian samples)
```

**Specifications**:
- Sample rate: 16000 Hz (Groq API requirement)
- Channels: 1 (mono)
- Bit depth: 16-bit signed PCM
- Byte order: Little-endian
- Format: Non-extensible (44-byte header, max compatibility)

**Duration Calculation**:
```swift
public static func estimateDuration(from wavData: Data) -> TimeInterval {
    guard wavData.count > 44 else { return 0 }
    let pcmBytes = wavData.count - 44
    return TimeInterval(pcmBytes) / TimeInterval(16000 * 2)
    // Duration = PCM_bytes / (sample_rate * bytes_per_sample)
}
```

### Audio Interruption Handling
**File**: `/Users/junlin/Documents/GitHub/local_stt/ios/Sources/LocalSTT/Services/AudioRecorder.swift` (lines 154-178)

```swift
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
                self.onInterruption?()  // Callback to AppState
            }
        case .ended:
            // Reactivate audio session
            try? AVAudioSession.sharedInstance().setActive(true)
        @unknown default:
            break
        }
    }
}
```

**Integration with AppState**:
```swift
recorder.onInterruption = { [weak self] in
    self?.state = .error("Recording interrupted")
    self?.recordingDuration = 0
    self?.scheduleErrorReset()  // 3s auto-reset to .ready
}
```

### Minimum Duration Filter
**File**: `/Users/junlin/Documents/GitHub/local_stt/ios/Sources/LocalSTT/AppState.swift` (line 51)

```swift
private let minRecordingDuration: TimeInterval = 0.3

// In stopRecordingAndTranscribe()
if WAVEncoder.estimateDuration(from: wavData) < minRecordingDuration {
    state = .tooShort
    scheduleErrorReset()  // 3s, then back to .ready
    return
}
```

---

## 5. UI Component Map

### Main Views

#### RecordingView.swift (Lines 1-170)
**Location**: `/Users/junlin/Documents/GitHub/local_stt/ios/Sources/LocalSTT/Views/RecordingView.swift`

**Hierarchy**:
```
NavigationStack
└─ ZStack (appBackground)
   ├─ VStack (top-to-bottom layout)
   │  ├─ HistoryListView (compact=true, fills available space)
   │  ├─ statusArea (animated error/result/tooShort messages)
   │  ├─ RecordButton (120px height, full-width)
   │  ├─ LanguageBar (AUTO/EN/FR/中文 capsules)
   │  └─ quickAccessChips (VOCAB + REPLACE count badges)
   │
   └─ Toolbar (gear icon → SettingsView sheet)

Sheet Modifiers:
• showSettings → SettingsView()
• showVocabPanel → VocabularyPanelView()
• showReplacePanel → ReplacementPanelView()
```

**Key Features**:
- Infinite frame height on history (maxHeight: .infinity)
- No global animation (state changes must be instant)
- 480px max width (iPad constraint)
- Dark theme enforced (preferredColorScheme(.dark))
- Quick-access chips at bottom above safe area (34pt padding)

#### RecordButton.swift (Lines 1-193)
**Location**: `/Users/junlin/Documents/GitHub/local_stt/ios/Sources/LocalSTT/Views/RecordButton.swift`

**Visual States**:
- `.recording`: Red fill (opacity 0.1), red border (3pt), white duration timer
- `.transcribing`: Amber fill (opacity 0.08), amber border, ProgressView
- Default: Teal fill (opacity 0.08), teal border (2pt), mic icon

**Dimensions**:
- Height: 120px
- Border radius: 20px
- Horizontal padding: 20pt (within RecordingView)

**Gesture Handling**:
- Uses HoldGestureView (UILongPressGestureRecognizer wrapper)
- minimumPressDuration: 0 (immediate touch-down)
- Callbacks: onBegan → startRecording(), onEnded → stopRecording()

**Duration Timer**:
```swift
// 1Hz timer (M:SS format), not continuous
// Reduces @Observable invalidations
timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
    guard case .recording = appState.state else { return }
    appState.recordingDuration += 1.0
}
```

**Pulse Animation** (recording state):
```swift
RoundedRectangle(cornerRadius: cornerRadius)
    .stroke(Color.recordingRed, lineWidth: 3)
    .scaleEffect(pulseAnimation ? 1.02 : 1.0)
    .opacity(pulseAnimation ? 0.7 : 1.0)
    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulseAnimation)
```

#### WaveformView.swift (Lines 1-36)
**Location**: `/Users/junlin/Documents/GitHub/local_stt/ios/Sources/LocalSTT/Views/WaveformView.swift`

**Design**:
- 40 vertical bars (3px width, 2px spacing)
- Max height: 50px
- Fill color: recordingRed
- Frame height: 50pt

**Animation**:
```swift
// Shift bars left, add new RMS on right
var updated = levels
updated.removeFirst()
let jitter = CGFloat.random(in: 0.8...1.2)  // ±20% random
updated.append(CGFloat(newRMS) * jitter)
levels = updated

// Smooth easing per bar
.animation(.easeOut(duration: 0.08), value: levels[index])
```

**Reactive**:
- Observes AudioRecorder.currentRMS via onChange
- Only visible during recording (offscreen when hidden)

#### LanguageBar.swift (Lines 1-54)
**Location**: `/Users/junlin/Documents/GitHub/local_stt/ios/Sources/LocalSTT/Views/LanguageBar.swift`

**Options**:
```swift
[("AUTO", ""), ("EN", "en"), ("FR", "fr"), ("中文", "zh")]
```

**Styling**:
- Selected: Teal fill, dark text
- Unselected: appSurface fill, muted text
- Border radius: Capsule
- Spacing: 8pt between buttons

**Fallback Logic**:
```swift
private func isSelected(_ code: String) -> Bool {
    if code.isEmpty {
        // AUTO = empty string OR unknown code
        return language.isEmpty || !options.dropFirst().contains(where: { $0.code == language })
    }
    return language == code
}
```

#### HistoryListView.swift (Lines 1-310)
**Location**: `/Users/junlin/Documents/GitHub/local_stt/ios/Sources/LocalSTT/Views/HistoryListView.swift`

**Modes**:
1. **Compact** (isCompact=true, used on main screen)
   - ScrollView with custom cards
   - LazyVStack (8pt spacing)
   - Tap to copy, delete inline button
   - Scroll-to-top on new result

2. **Full** (isCompact=false, used in history sheet)
   - Native List with swipe-to-delete
   - Tap to copy
   - Works with onDelete modifier

**Card Design** (compact):
```
┌─ 3pt teal left accent (if highlighted) ─┐
│ [Text]           [Usage badge]           │
│ [EN] 0.5s 2m ago [Copy/Delete buttons]   │
└──────────────────────────────────────────┘
```

**Copy Action**:
```swift
func copyToClipboard(_ item: TranscriptionResult) {
    UIPasteboard.general.string = item.text
    withAnimation(.easeInOut(duration: 0.2)) {
        copiedID = item.id
    }
    // Flash "Copied" for 1s
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        withAnimation { copiedID = nil }
    }
}
```

**Search Highlighting**:
- Real-time filter by text.localizedCaseInsensitiveContains()
- Highlights matches in teal with .bold()
- Shows count: (N/M)

#### VocabularyPanelView.swift (Lines 1-97)
**Location**: `/Users/junlin/Documents/GitHub/local_stt/ios/Sources/LocalSTT/Views/VocabularyPanelView.swift`

**Layout**:
```
Form
├─ Section (Add word)
│  ├─ TextField "Add word or phrase..."
│  ├─ Plus button (teal, disabled if empty)
│  └─ Error message (red, if add fails)
│
└─ Section "Words (ordered by usage)"
   ├─ ForEach word in vocabularyWords
   │  ├─ Word text
   │  ├─ Usage badge (×N)
   │  └─ Delete button (×, gray)
   └─ Footer: "N/85 words"
```

**Error Messages**:
- "Empty word" (trimmed input is blank)
- "Word already exists" (case-insensitive)
- "Vocabulary limit reached (85 words). Remove a word first."

**UX Details**:
- onSubmit on TextField triggers addWord()
- Usage counts sourced from vocabularyUsageCounts (mirrored from manager)
- Plus button disabled while empty
- Teal delete icon → plain buttonStyle (no background)

#### ReplacementPanelView.swift (Lines 1-117)
**Location**: `/Users/junlin/Documents/GitHub/local_stt/ios/Sources/LocalSTT/Views/ReplacementPanelView.swift`

**Layout**:
```
Form
├─ Section (Enable toggle)
│  └─ Toggle "Enable replacements"
│
├─ Section (Add rule)
│  ├─ TextField "From..."
│  ├─ Image "arrow.right" (gray)
│  ├─ TextField "To..."
│  ├─ Plus button (teal)
│  └─ Error message (red, if add fails)
│
└─ Section "Replacements (N/100 rules)"
   ├─ ForEach rule in replacementRules
   │  ├─ "from" text
   │  ├─ Arrow icon
   │  ├─ "to" text (teal)
   │  └─ Delete button (×)
   └─ Footer: "Case-insensitive whole-word..."
```

**Error Messages**:
- "Source text is required"
- "Replacement text is required"
- "Replacement for 'X' already exists" (case-insensitive)
- "Replacement limit reached (100 rules). Remove a rule first."

**Toggle State**:
```swift
Toggle("Enable replacements", isOn: Binding(
    get: { appState.replacementsEnabled },
    set: {
        appState.replacementManager.isEnabled = $0
        appState.syncReplacements()  // Update mirror
    }
))
```

#### SettingsView.swift (Lines 1-107)
**Location**: `/Users/junlin/Documents/GitHub/local_stt/ios/Sources/LocalSTT/Views/SettingsView.swift`

**Layout**:
```
Form
└─ Section "Groq API Key"
   ├─ HStack (input + eye toggle)
   │  ├─ TextField/SecureField "gsk_..."
   │  └─ Eye icon button (toggle showAPIKey)
   │
   ├─ HStack (Save + Test buttons)
   │  ├─ "Save Key" (disabled if empty)
   │  ├─ Spacer
   │  └─ Test button
   │     ├─ ProgressView (if testing)
   │     ├─ ✓ green (if valid)
   │     ├─ ✗ red (if invalid)
   │     └─ "Test" (if untested)
   │
   └─ Footer: "Get your free API key from console.groq.com"
```

**Key Test Flow**:
```swift
private func testAPIKey() {
    isTesting = true
    testResult = nil

    let serviceToTest = GroqService(apiKey: apiKey)
    Task {
        let result = await serviceToTest.testConnection()
        isTesting = false
        testResult = result  // ✓ or ✗

        Task {
            try? await Task.sleep(for: .seconds(3))
            testResult = nil  // Clear after 3s
        }
    }
}
```

#### TranscriptionHistoryView.swift (Lines 1-42)
**Location**: `/Users/junlin/Documents/GitHub/local_stt/ios/Sources/LocalSTT/Views/TranscriptionHistoryView.swift`

**Layout**:
```
NavigationStack
└─ Group
   ├─ ContentUnavailableView (if empty)
   │  └─ "No Transcriptions"
   │
   └─ HistoryListView (isCompact=false, full List mode)

Toolbar
├─ Leading: "Clear All" button (destructive role)
└─ Trailing: "Done" button
```

**Sheets Integration**:
- Triggered from RecordingView via NavigationLink (commented but view structure present)

#### ResultCard.swift (Lines 1-84)
**Location**: `/Users/junlin/Documents/GitHub/local_stt/ios/Sources/LocalSTT/Views/ResultCard.swift`

**Layout**:
```
VStack (spacing: 12)
├─ Text (result.text, selectable)
│
└─ HStack
   ├─ Language badge (teal)
   ├─ Duration label (with waveform icon)
   ├─ Processing time (with bolt icon)
   ├─ Spacer
   ├─ "Copied" indicator (if just copied)
   │  OR
   └─ Copy button (if not copied)
```

**Usage**:
- Used in compact history cards
- Text selection enabled (.textSelection(.enabled))
- Copy button toggles "Copied" state with 2s auto-reset

---

## 6. Vocabulary System (Detailed)

### File Structure
**Location**: `~/Library/Application Support/LocalSTT/`

#### vocabulary.txt
```
# Custom vocabulary for speech-to-text
# One word/phrase per line, comments start with #
# Words are case-sensitive (TEMPEST stays TEMPEST)
# Ordered by usage frequency (most-used first)

MCP
MCP tool
subagent
TEMPEST
Slack
...
```

**Format**:
- Plain text, UTF-8
- One word/phrase per line
- Comments: Lines starting with #
- Blanks: Ignored
- Case-sensitive (MCP ≠ mcp)
- Ordered by usage on save

#### vocabulary_usage.json
```json
{
  "MCP": 532,
  "MCP tool": 147,
  "subagent": 218,
  "TEMPEST": 110,
  "Slack": 114,
  ...
}
```

**Format**:
- JSON dictionary {word: usage_count}
- Updated on recordUsage() call
- Persisted atomically

### Prompt Building (ported from groq_stt.py:_build_prompt)
**File**: `/Users/junlin/Documents/GitHub/local_stt/ios/Sources/LocalSTTCore/VocabularyManager.swift` (lines 261-286)

```swift
public func buildPrompt(maxWords: Int = 0) -> String? {
    let vocab = words
    guard !vocab.isEmpty else { return nil }

    let source = maxWords > 0 ? Array(vocab.prefix(maxWords)) : vocab

    let prefix = "Vocabulary: "
    let suffix = "."
    var currentLength = prefix.count + suffix.count
    var included: [String] = []

    for word in source {
        let separator = included.isEmpty ? "" : ", "
        let addition = separator.count + word.count

        if currentLength + addition <= Self.maxPromptLength {
            included.append(word)
            currentLength += addition
        } else {
            break  // Stop adding words
        }
    }

    guard !included.isEmpty else { return nil }
    return "\(prefix)\(included.joined(separator: ", "))\(suffix)"
}
```

**Output Example**:
```
"Vocabulary: MCP, MCP tool, subagent, TEMPEST, Slack, Railway, markdown."
```

**Constraints**:
- Max prompt length: 896 characters (Groq API limit)
- Truncates word list to fit
- Returns nil if vocabulary empty or no words fit

### Casing Correction
**File**: `/Users/junlin/Documents/GitHub/local_stt/ios/Sources/LocalSTTCore/VocabularyManager.swift` (lines 297-329)

```swift
public func applyVocabularyCasing(to text: String) -> (String, [String]) {
    let vocab = words
    guard !vocab.isEmpty else { return (text, []) }

    var result = text
    var matched: [String] = []

    for word in vocab {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        // \b word boundary — case-insensitive matching
        guard let regex = try? NSRegularExpression(
            pattern: "\\b\(escaped)\\b",
            options: .caseInsensitive
        ) else { continue }

        let range = NSRange(result.startIndex..., in: result)
        if regex.firstMatch(in: result, range: range) != nil {
            matched.append(word)
            // Escape replacement template ($, \, & → \$, \\, \&)
            let escapedTemplate = word
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "$", with: "\\$")
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: escapedTemplate
            )
        }
    }

    return (result, matched)
}
```

**Behavior**:
- Input: "the mcp and tempest projects"
- Output: ("the MCP and TEMPEST projects", ["MCP", "TEMPEST"])
- Matching: Case-insensitive, word-boundary only (\\b)
- Replacement: Canonical form from vocabulary
- Returns tuple (corrected_text, matched_words)

**Regex Template Escaping**:
- NSRegularExpression interprets $0, $1, \ as special
- Must escape: $ → \$, \ → \\, & → \&
- Prevents: CO$T → wrong replacement, A\B → wrong replacement

### Usage Tracking
**File**: `/Users/junlin/Documents/GitHub/local_stt/ios/Sources/LocalSTTCore/VocabularyManager.swift` (lines 175-209)

```swift
public func recordUsage(for matchedWords: [String]) {
    guard !matchedWords.isEmpty else { return }
    _usage.increment(matchedWords)
    saveUsageToFile()
}

// In AppState.stopRecordingAndTranscribe():
let (corrected, matchedWords) = vocabularyManager.applyVocabularyCasing(to: result.text)
vocabularyManager.recordUsage(for: matchedWords)
syncVocabulary()  // Update UI mirrors
```

**Flow**:
1. applyVocabularyCasing() returns matched words
2. recordUsage() increments counts
3. syncVocabulary() updates AppState mirrors for UI
4. saveToFile() is called by recordUsage(), reorders by count

**Reordering**:
```swift
private func reorderByUsage() {
    let counts = _usage.value
    guard !counts.isEmpty else { return }

    var current = _words.value
    current.sort { a, b in
        let countA = counts[a] ?? 0
        let countB = counts[b] ?? 0
        return countA > countB  // Descending order
    }
    _words.set(current)
}
```

### File I/O
**Location**: VocabularyManager.swift (lines 145-171)

#### Load
```swift
public func loadFromFile() {
    guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }

    let loaded = content
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }

    _words.set(Array(loaded.prefix(Self.maxVocabularySize)))
}
```

#### Save
```swift
public func saveToFile() {
    reorderByUsage()

    var lines = [
        "# Custom vocabulary for speech-to-text",
        "# One word/phrase per line, comments start with #",
        "# Words are case-sensitive (TEMPEST stays TEMPEST)",
        "",
    ]
    lines.append(contentsOf: words)
    lines.append("")

    let content = lines.joined(separator: "\n")
    try? content.write(to: fileURL, atomically: true, encoding: .utf8)
}
```

### Bundled Vocabulary
**Location**: `/Users/junlin/Documents/GitHub/local_stt/ios/Resources/vocabulary.txt`

**Copy Logic** (AppState.init()):
```swift
let bundledVocab = Bundle.main.url(forResource: "vocabulary", withExtension: "txt")
let bundledUsage = Bundle.main.url(forResource: "vocabulary_usage", withExtension: "json")
self.vocabularyManager = VocabularyManager(
    bundledFileURL: bundledVocab,
    bundledUsageURL: bundledUsage
)
```

**First-Launch Copy**:
```swift
// In VocabularyManager.init()
if !FileManager.default.fileExists(atPath: fileURL.path) {
    if let bundled = bundledFileURL {
        try? FileManager.default.copyItem(at: bundled, to: fileURL)
    }
}

// Upgrade scenario (file exists but is empty)
if _words.value.isEmpty, let bundled = bundledFileURL,
   FileManager.default.fileExists(atPath: bundled.path) {
    try? FileManager.default.removeItem(at: fileURL)
    try? FileManager.default.copyItem(at: bundled, to: fileURL)
    loadFromFile()
}
```

### Limits & Constraints
- **Max vocabulary size**: 85 words (VocabularyManager.maxVocabularySize)
- **Max prompt length**: 896 characters (VocabularyManager.maxPromptLength)
- **Enforced in**: addWord() blocks when count >= 85, buildPrompt() truncates

---

## 7. Replacement System (Detailed)

### File Structure
**Location**: `~/Library/Application Support/LocalSTT/replacements.json`

```json
{
  "replacements": [
    {"from": "Cloud Code", "to": "Claude Code"},
    {"from": "Clock code", "to": "Claude Code"},
    {"from": "cloud.md", "to": "CLAUDE.md"},
    ...
  ]
}
```

**Format**:
- JSON with top-level "replacements" key
- Array of objects: {from, to} (id optional, synthesized if missing)
- Pretty-printed on save

### Rule Management
**File**: `/Users/junlin/Documents/GitHub/local_stt/ios/Sources/LocalSTTCore/ReplacementManager.swift`

#### Add Rule
```swift
public func addRule(from: String, to: String) -> (Bool, String?) {
    let fromTrimmed = from.trimmingCharacters(in: .whitespaces)
    let toTrimmed = to.trimmingCharacters(in: .whitespaces)

    guard !fromTrimmed.isEmpty else { return (false, "Source text is required") }
    guard !toTrimmed.isEmpty else { return (false, "Replacement text is required") }

    if rules.count >= Self.maxRules {
        return (false, "Replacement limit reached (100 rules)...")
    }

    // Case-insensitive duplicate check
    if rules.contains(where: { $0.from.caseInsensitiveCompare(fromTrimmed) == .orderedSame }) {
        return (false, "Replacement for '\(fromTrimmed)' already exists")
    }

    var current = rules
    current.append(ReplacementRule(from: fromTrimmed, to: toTrimmed))
    _rules.set(current)
    saveToFile()
    return (true, nil)
}
```

#### Remove Rule
```swift
public func removeRule(_ rule: ReplacementRule) -> Bool {
    var current = rules
    guard let index = current.firstIndex(where: { $0.id == rule.id }) else { return false }
    current.remove(at: index)
    _rules.set(current)
    saveToFile()
    return true
}
```

### Replacement Application
**File**: ReplacementManager.swift (lines 175-200)

```swift
public func applyReplacements(to text: String) -> String {
    guard isEnabled else { return text }

    let (currentRules, patterns) = _rules.valueAndPatterns()
    guard !currentRules.isEmpty, !text.isEmpty else { return text }

    var result = text
    for (rule, regex) in zip(currentRules, patterns) {
        guard let regex else { continue }

        let range = NSRange(result.startIndex..., in: result)
        // Escape $ → \$, \ → \\, & → \&
        let escapedTemplate = rule.to
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "&", with: "\\&")
        result = regex.stringByReplacingMatches(
            in: result,
            range: range,
            withTemplate: escapedTemplate
        )
    }

    return result
}
```

**Execution Order**:
- Rules applied sequentially, top-to-bottom
- Each rule operates on output of previous
- Example:
  ```
  Input: "Cloud Code is Cloud Code"
  Rule 1: "Cloud Code" → "Claude Code"
  Output: "Claude Code is Claude Code"
  ```

### Regex Pattern Compilation
**File**: ReplacementManager.swift (lines 42-50)

```swift
func set(_ newValue: [ReplacementRule]) {
    lock.lock()
    defer { lock.unlock() }
    storage = newValue
    compiledRegex = newValue.map { rule in
        let escaped = NSRegularExpression.escapedPattern(for: rule.from)
        return try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: .caseInsensitive)
    }
}
```

**Pattern Format**:
- Escapes special regex chars in `from` text
- Adds word boundaries: \\b..\\b
- Case-insensitive matching
- Stored in parallel array for performance

**Example**:
- Input: "Cloud Code" (from field)
- Escaped: "Cloud\\ Code"
- Pattern: "\\bCloud\\ Code\\b"
- Matches: "cloud code", "CLOUD CODE", but not "CloudCode" or "Cloud Codes"

### Thread-Safety
**File**: ReplacementManager.swift (lines 17-51)

```swift
private final class ManagedRules: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ReplacementRule] = []
    private var compiledRegex: [NSRegularExpression?] = []

    func valueAndPatterns() -> ([ReplacementRule], [NSRegularExpression?]) {
        lock.lock()
        defer { lock.unlock() }
        return (storage, compiledRegex)
    }
}
```

**Lock Strategy**:
- NSLock for read/write synchronization
- Atomic fetch of (rules, patterns) tuple
- Prevents data race when applyReplacements() reads while addRule() writes

### Enable/Disable Toggle
**File**: ReplacementManager.swift (lines 57-60)

```swift
public var isEnabled: Bool {
    get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
}
```

**Default**: true on first launch (line 79)

### Limits & Constraints
- **Max rules**: 100 (ReplacementManager.maxRules)
- **Enforced in**: addRule() blocks when count >= 100
- **Case sensitivity**: Matching is case-insensitive, replacement text exact

---

## 8. API Integration (Groq Whisper)

### Service Implementation
**File**: `/Users/junlin/Documents/GitHub/local_stt/ios/Sources/LocalSTTCore/GroqService.swift`

#### Transcription Request
```swift
public func transcribe(
    wavData: Data,
    language: String? = nil,
    prompt: String? = nil
) async throws -> TranscriptionResult {
    let startTime = Date()

    let (body, contentType) = buildMultipartBody(
        wavData: wavData,
        language: language,
        prompt: prompt
    )

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    request.httpBody = body

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
        throw GroqError.invalidResponse
    }

    guard httpResponse.statusCode == 200 else {
        let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
        throw GroqError.httpError(statusCode: httpResponse.statusCode, body: errorBody)
    }

    let groqResponse = try JSONDecoder().decode(GroqResponse.self, from: data)
    let processingTime = Date().timeIntervalSince(startTime)

    let duration = groqResponse.duration
        ?? WAVEncoder.estimateDuration(from: wavData)

    return TranscriptionResult(
        text: groqResponse.text.trimmingCharacters(in: .whitespacesAndNewlines),
        language: groqResponse.language ?? language ?? "unknown",
        duration: duration,
        processingTime: processingTime
    )
}
```

#### API Details
- **Model**: whisper-large-v3-turbo
- **Endpoint**: https://api.groq.com/openai/v1/audio/transcriptions
- **Auth**: Bearer token from Keychain
- **Format**: multipart/form-data
- **Response**: JSON with text, language, duration fields

#### Multipart Body Building
```swift
public func buildMultipartBody(
    wavData: Data,
    language: String?,
    prompt: String?
) -> (Data, String) {
    let boundary = "Boundary-\(UUID().uuidString)"
    var body = Data()

    // Fields in order
    body.appendFormField(name: "model", value: model, boundary: boundary)
    body.appendFormField(name: "response_format", value: "verbose_json", boundary: boundary)

    if let language, !language.isEmpty {
        body.appendFormField(name: "language", value: language, boundary: boundary)
    }

    if let prompt, !prompt.isEmpty {
        body.appendFormField(name: "prompt", value: prompt, boundary: boundary)
    }

    body.appendFormFile(
        name: "file", filename: "audio.wav", mimeType: "audio/wav",
        data: wavData, boundary: boundary
    )

    body.append("--\(boundary)--\r\n".data(using: .utf8)!)

    let contentType = "multipart/form-data; boundary=\(boundary)"
    return (body, contentType)
}
```

**Field Order**: model, response_format, language (if provided), prompt (if provided), file

**Helper Extensions** (lines 155-169):
```swift
extension Data {
    mutating func appendFormField(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendFormFile(name: String, filename: String, mimeType: String, data: Data, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }
}
```

### Error Handling
**File**: GroqService.swift (lines 133-151)

```swift
public enum GroqError: LocalizedError, Sendable {
    case missingAPIKey
    case httpError(statusCode: Int, body: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Groq API key not configured. Add it in Settings."
        case .httpError(let code, let body):
            if code == 401 {
                return "Invalid Groq API key. Check Settings."
            }
            return "Groq API error (\(code)): \(body)"
        case .invalidResponse:
            return "Invalid response from Groq API."
        }
    }
}
```

### Connection Testing
```swift
public func testConnection() async -> Bool {
    // Create a minimal 0.1s silent WAV to test the API
    let silentSamples = Data(count: WAVEncoder.sampleRate / 10 * WAVEncoder.bytesPerSample)
    let wavData = WAVEncoder.encode(pcmData: silentSamples)

    do {
        _ = try await transcribe(wavData: wavData)
        return true
    } catch {
        return false
    }
}
```

**Used by**: SettingsView test button (creates temporary GroqService)

### Response Model
```swift
struct GroqResponse: Decodable {
    let text: String
    let language: String?
    let duration: TimeInterval?
}
```

---

## 9. Hallucination Filtering (Detailed)

### Detection Algorithm
**File**: `/Users/junlin/Documents/GitHub/local_stt/ios/Sources/LocalSTTCore/HallucinationFilter.swift`

```swift
public static func isHallucination(_ text: String) -> Bool {
    let normalized = text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: "\u{2019}", with: "'")  // ' → '
    guard !normalized.isEmpty else { return false }
    return phrases.contains(normalized)
}
```

**Logic**:
1. Trim whitespace
2. Convert to lowercase
3. Normalize typographic apostrophe (U+2019 → U+0027)
4. Check exact match against Set<String>

**Critical Feature**: Entire text match only—partial matches ignored

### Detected Phrases

#### English (20 phrases with variants)
```
"thank you", "thank you.", "thanks", "thanks.",
"thanks for watching", "thanks for watching.",
"thanks for listening", "thanks for listening.",
"thank you for watching", "thank you for watching.",
"thank you for listening", "thank you for listening.",
"like and subscribe", "like and subscribe.",
"subscribe", "subscribe.",
"see you next time", "see you next time.",
"bye", "bye.", "goodbye", "goodbye.",
"see you", "see you.",
"you", "you."
```

#### Chinese (4 phrases)
```
"謝謝", "谢谢", "謝謝觀看", "谢谢观看"
```

#### Japanese (3 phrases)
```
"ありがとう", "ありがとうございます", "ご視聴ありがとうございました"
```

#### French (3 phrases)
```
"merci", "merci.", "merci d'avoir regardé"
```

#### Punctuation/Other (3 phrases)
```
"...", "…"
```

**Total**: 50+ phrases

### Period Variants
**Rationale**: Whisper sometimes adds periods, sometimes doesn't
```
"thank you" and "thank you."  → Both stored
"thanks" and "thanks."        → Both stored
"bye" and "bye."              → Both stored
```

### Apostrophe Normalization
```swift
.replacingOccurrences(of: "\u{2019}", with: "'")  // U+2019 → U+0027
```

**Reason**: Whisper may output right single quotation mark (') in French
```
Input: "merci d'avoir regardé"  (with U+2019)
Normalized: "merci d'avoir regardé"  (with U+0027)
Match: Set contains "merci d'avoir regardé" (with U+0027)
Result: true ✓
```

### Integration with AppState
**File**: AppState.swift (lines 218-223)

```swift
// 4. Check for hallucination
if HallucinationFilter.isHallucination(finalText) {
    state = .error("Discarded (hallucination detected)")
    scheduleErrorReset()  // 3s auto-reset to .ready
    return
}
```

**Order in Pipeline**:
1. Vocabulary casing (canonical form)
2. Record usage
3. Replacements (if enabled)
4. **Hallucination filter** ← runs last (after replacements!)
5. Auto-paste

---

## 10. Settings & Configuration

### Persistent Storage

#### UserDefaults (Device)
| Key | Type | Default | Usage |
|-----|------|---------|-------|
| `stt_language` | String | "" (auto) | Language selection |
| `transcription_history` | Data (JSON) | [] | Up to 100 TranscriptionResults |
| `replacements_enabled` | Bool | true | Enable/disable replacement rules |

#### Keychain (Secure)
| Account | Service | Value |
|---------|---------|-------|
| `groq_api_key` | `com.localSTT.app` | Bearer token (SecureField) |

#### File System (Application Support)
| Path | Type | Contents |
|------|------|----------|
| `LocalSTT/vocabulary.txt` | Text | One word per line, comments |
| `LocalSTT/replacements.json` | JSON | {replacements: [{from, to}]} |
| `LocalSTT/vocabulary_usage.json` | JSON | {word: count} |

### Configuration Constants

#### Audio
| Constant | Value | Source |
|----------|-------|--------|
| Sample rate | 16000 Hz | WAVEncoder.sampleRate |
| Channels | 1 (mono) | WAVEncoder.channels |
| Bit depth | 16-bit PCM | WAVEncoder.bitsPerSample |
| Buffer size | 4096 frames | AudioRecorder.start() |
| RMS normalization | ×5 multiplier | AudioRecorder (line 98) |

#### Recording
| Constant | Value | Source |
|----------|-------|--------|
| Min recording duration | 0.3s | AppState (line 51) |
| Recording timer frequency | 1 Hz | RecordButton (line 130) |
| Error auto-reset delay | 3s | AppState.scheduleErrorReset() |

#### Vocabulary
| Constant | Value | Source |
|----------|-------|--------|
| Max vocabulary size | 85 words | VocabularyManager.maxVocabularySize |
| Max prompt length | 896 chars | VocabularyManager.maxPromptLength |
| Prompt format | "Vocabulary: X, Y, Z." | VocabularyManager.buildPrompt() |

#### Replacements
| Constant | Value | Source |
|----------|-------|--------|
| Max replacement rules | 100 rules | ReplacementManager.maxRules |
| Matching | Case-insensitive, whole-word | ReplacementManager.applyReplacements() |

#### History
| Constant | Value | Source |
|----------|-------|--------|
| Max history items | 100 results | AppState.maxHistory |
| Persisted in | UserDefaults | AppState.loadHistory() |

### Info.plist Configuration
**Location**: `/Users/junlin/Documents/GitHub/local_stt/ios/Resources/Info.plist`

```xml
<key>NSMicrophoneUsageDescription</key>
<string>LocalSTT needs microphone access to record audio for speech-to-text transcription.</string>

<key>CFBundleName</key>
<string>LocalSTT</string>

<key>CFBundleDisplayName</key>
<string>Local STT</string>

<key>CFBundleIdentifier</key>
<string>com.localSTT.app</string>

<key>UISupportedInterfaceOrientations</key>
<array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
</array>

<key>UISupportedInterfaceOrientations~ipad</key>
<array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationPortraitUpsideDown</string>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
</array>
```

---

## 11. Test Coverage

### Test Files
| Test File | Coverage | Key Tests |
|-----------|----------|-----------|
| GroqServiceTests.swift | Multipart building, error handling, response decoding | 10 tests |
| HallucinationFilterTests.swift | Phrase matching, case insensitivity, whitespace, apostrophe normalization | 16 tests |
| ReplacementManagerTests.swift | CRUD, regex, file I/O, enable/disable toggle | 12 tests |
| VocabularyManagerTests.swift | Prompt building, casing correction, usage tracking, file I/O, word management | 25 tests |
| TranscriptionResultTests.swift | Duration/time formatting, relative timestamps | (Exists, content not examined) |
| WAVEncoderTests.swift | WAV header format, duration estimation | (Exists, content not examined) |

### Example: VocabularyManagerTests
**File**: `/Users/junlin/Documents/GitHub/local_stt/ios/Tests/LocalSTTCoreTests/VocabularyManagerTests.swift`

**Key Test Cases**:
1. **Initialization** (lines 8-21)
   - testInitWithWordList: ["MCP", "TEMPEST", "Claude Code"]
   - testInitEnforcesMaxSize: Truncates to 85 words

2. **Prompt Building** (lines 25-73)
   - testBuildPromptBasic: "Vocabulary: MCP, TEMPEST, STT."
   - testBuildPromptTruncation: Respects 896 char limit
   - testBuildPromptMaxWords: Limits to N words

3. **Vocabulary Casing** (lines 77-158)
   - testApplyVocabularyCasingBasic: "mcp" → "MCP"
   - testApplyVocabularyCasingWordBoundary: "STT" ≠ "STUTTERING"
   - testApplyVocabularyCasingRegexTemplateEscaping: "CO$T", "A\\B" handled correctly

4. **File I/O** (lines 211-269)
   - testFileRoundTrip: Write + read = same words
   - testBundledFileCopy: Copies on first launch
   - testLoadSkipsCommentsAndBlanks: Parses correctly

5. **Usage Tracking** (lines 273-334)
   - testRecordUsage: Increments counters
   - testReorderByUsage: Sorts by count descending
   - testUsageFileRoundTrip: Persists JSON correctly

---

## 12. Code Quality & Architecture Decisions

### Strengths

1. **Modular Design**
   - LocalSTTCore package separate from app UI
   - Services (GroqService, AudioRecorder, VocabularyManager, ReplacementManager) are cohesive
   - Testable without UI dependencies

2. **Thread-Safety**
   - NSLock usage in VocabularyManager, ReplacementManager
   - Sendable conformance for async contexts
   - No shared mutable state without locking

3. **File Persistence**
   - Application Support directory (respects app sandboxing)
   - Atomic writes (preserves data integrity on crash)
   - Pretty-printing for readability

4. **Error Handling**
   - Custom GroqError enum with LocalizedError
   - User-friendly messages in UI
   - Graceful fallbacks (e.g., duration estimation from WAV bytes)

5. **UI/State Separation**
   - @Observable pattern for reactivity (iOS 17+)
   - Observable mirrors for frequently-changing data
   - Clear state machine (RecordingState enum)

### Potential Improvements (Not Issues, Design Choices)

1. **Vocabulary Ordering**
   - Currently reordered on every save (O(n log n) sort)
   - Could cache sort state, but vocabulary is small (max 85 words)

2. **UILongPressGestureRecognizer**
   - Via UIViewRepresentable bridge (necessary due to SwiftUI DragGesture issues)
   - Not elegant, but pragmatic workaround

3. **Observable Mirrors**
   - VocabularyManager, ReplacementManager not @Observable
   - Manual syncVocabulary(), syncReplacements() calls needed
   - Alternative: @Observable wrappers (added complexity)

### Testing Strategy

- **Unit tests** for core business logic (GroqService, VocabularyManager, ReplacementManager, HallucinationFilter, WAVEncoder)
- **No UI tests** (SwiftUI testing is complex; focus on logic is appropriate)
- **Fixtures** for file I/O tests (temporary directories with FileManager)
- **Mock data** for API tests (multipart body inspection)

---

## 13. Deployment & Build Configuration

### Package.swift
**Location**: `/Users/junlin/Documents/GitHub/local_stt/ios/Package.swift`

```swift
let package = Package(
    name: "LocalSTT",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "LocalSTTCore", targets: ["LocalSTTCore"]),
    ],
    targets: [
        .target(name: "LocalSTTCore", path: "Sources/LocalSTTCore"),
        .testTarget(
            name: "LocalSTTCoreTests",
            dependencies: ["LocalSTTCore"],
            path: "Tests/LocalSTTCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
```

**Key Points**:
- Platforms: iOS 17+ required (@Observable, async/await)
- macOS 14+ declared but not implemented (no macOS UI)
- Single library product (LocalSTTCore)
- Test resources supported (Fixtures directory)

### Requirements
| Component | Version | Reason |
|-----------|---------|--------|
| iOS | 17+ | @Observable, AVAudioEngine reliability |
| macOS | 14+ | (Declared but not implemented) |
| Swift | 5.9+ | Async/await, Package.swift syntax |
| Xcode | 15+ | iOS 17 SDK |

### Binary Size
- **LocalSTTCore**: ~100KB (no external dependencies)
- **App bundle**: ~5-10MB (SwiftUI runtime + resources)

### External Dependencies
**None** (pure Foundation + SwiftUI + AVFoundation)

---

## 14. Known Limitations & Future Considerations

### Current Limitations
1. **iOS Only**: macOS target declared but no UI implementation
2. **Single STT Provider**: Only Groq API (backend supports multiple, iOS only does Groq)
3. **No Cloud Sync**: Vocabulary/replacements/history are device-local
4. **No Batch Transcription**: Single audio file per request
5. **No Voice Activity Detection**: Minimum duration filter only (0.3s threshold)

### Future Features (Not Implemented)
1. **macOS App**: Reuse LocalSTTCore, build SwiftUI UI for macOS
2. **OpenAI Whisper API**: Add as alternative to Groq
3. **Vocabulary Sync**: iCloud/CloudKit sync across devices
4. **Shortcuts Integration**: iOS Shortcuts for automation
5. **Microphone Permission Request**: Currently required before first recording attempt
6. **Audio Level Visualization**: WaveformView shows RMS, could add frequency spectrum
7. **Custom Wake Word**: Audio trigger for automated transcription

---

## 15. File Structure & Paths

### Source Layout
```
/Users/junlin/Documents/GitHub/local_stt/ios/
├── Sources/
│   ├── LocalSTTCore/
│   │   ├── GroqService.swift
│   │   ├── AudioRecorder.swift  (moved from app layer for testing)
│   │   ├── VocabularyManager.swift
│   │   ├── ReplacementManager.swift
│   │   ├── ReplacementRule.swift
│   │   ├── HallucinationFilter.swift
│   │   ├── TranscriptionResult.swift
│   │   ├── WAVEncoder.swift
│   │   └── KeychainHelper.swift
│   │
│   └── LocalSTT/
│       ├── LocalSTTApp.swift
│       ├── AppState.swift
│       ├── Services/
│       │   └── AudioRecorder.swift  (or in LocalSTTCore?)
│       ├── Views/
│       │   ├── RecordingView.swift
│       │   ├── RecordButton.swift
│       │   ├── WaveformView.swift
│       │   ├── LanguageBar.swift
│       │   ├── HistoryListView.swift
│       │   ├── VocabularyPanelView.swift
│       │   ├── ReplacementPanelView.swift
│       │   ├── SettingsView.swift
│       │   ├── TranscriptionHistoryView.swift
│       │   └── ResultCard.swift
│       └── Utilities/
│           └── Color+Hex.swift
│
├── Tests/
│   └── LocalSTTCoreTests/
│       ├── GroqServiceTests.swift
│       ├── HallucinationFilterTests.swift
│       ├── ReplacementManagerTests.swift
│       ├── VocabularyManagerTests.swift
│       ├── TranscriptionResultTests.swift
│       └── WAVEncoderTests.swift
│
├── Resources/
│   ├── vocabulary.txt
│   ├── vocabulary_usage.json
│   ├── replacements.json
│   └── Info.plist
│
└── Package.swift
```

### Runtime Paths
```
Application Support:
~/Library/Application Support/LocalSTT/
├── vocabulary.txt
├── replacements.json
└── vocabulary_usage.json

Keychain:
Service: com.localSTT.app
Account: groq_api_key

UserDefaults:
com.localSTT.app (implicit)
├── stt_language
├── transcription_history
└── replacements_enabled
```

---

## 16. Dependencies & Imports Summary

### Foundation
- `Foundation` — Core types, Data, URL, UserDefaults, FileManager, NotificationCenter, Timer
- `AVFoundation` — AVAudioEngine, AVAudioSession, AVAudioFormat, AVAudioConverter, AVAudioPCMBuffer
- `Security` — SecItemAdd/Copy/Delete (Keychain)

### SwiftUI
- `SwiftUI` — @main, App, View, @Observable, @State, @Environment, Sheet, NavigationStack, Form, List
- `UIKit` (via #if canImport) — UIPasteboard, UIViewRepresentable, UILongPressGestureRecognizer, UFont, UIColor

### Modules
- `LocalSTTCore` — Imported by LocalSTT app for GroqService, VocabularyManager, ReplacementManager, HallucinationFilter, TranscriptionResult, WAVEncoder, KeychainHelper

---

## Summary for Mac Architect

**Key Features to Port to macOS**:
1. **Hold-to-Record Button** → Keyboard hotkey or mouse drag equivalent
2. **Waveform Visualization** → Same SwiftUI component (works on macOS)
3. **Vocabulary/Replacements Panels** → Native macOS UI (NSPanel or SwiftUI sheets)
4. **History Display** → macOS List or Table
5. **Keychain Storage** → Works identically on macOS (Security framework)
6. **Audio Recording** → AVAudioEngine + NSSound (simpler on macOS, no interruptions)
7. **File Persistence** → Application Support/LocalSTT/ (same directory structure)

**LocalSTTCore Reusability**: 100% portable—no iOS-specific code. Only UI needs macOS-specific implementation.

---

## Conclusion

The Local STT iOS app is a well-architected, production-ready speech-to-text client with sophisticated text processing capabilities, clean separation of concerns, and comprehensive test coverage. The core LocalSTTCore library is fully reusable for macOS/other platforms. Key strengths include modular design, thread-safety, secure credential storage, and user-friendly error handling. The codebase demonstrates professional Swift practices and is ready for enhancement or porting.
