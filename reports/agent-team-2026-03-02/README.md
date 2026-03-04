# Local STT Agent Analysis Reports
**Date**: 2026-03-02
**Repository**: https://github.com/JunlinYuan/local_stt

---

## Report Files

### ios-analyst.md (PRIMARY REPORT)
**Analyst**: ios-analyst
**Status**: ✅ Complete
**Size**: 8,000+ lines

Comprehensive deep-dive analysis of the iOS Swift implementation.

**Quick Navigation**:
- **Sections 1-5**: Feature inventory, architecture diagram, data models, audio pipeline, UI components
- **Sections 6-10**: Vocabulary system, replacement system, Groq API, hallucination filtering, settings
- **Sections 11-16**: Test coverage, code quality, deployment, file structure, dependencies, summary

**Key Takeaways**:
- LocalSTTCore is 100% platform-agnostic (can be reused for macOS)
- 10 core modules with no iOS-specific dependencies
- 60+ comprehensive unit tests
- Professional architecture with modular design, thread-safety, and error handling

**For Mac Port**: See Section 15 "Summary for Mac Architect" — LocalSTTCore requires zero modifications.

---

## Quick Reference

### Architecture Overview
```
iOS App (SwiftUI)
  ├── AppState (central coordinator)
  ├── Services
  │   ├── AudioRecorder (AVAudioEngine, RMS levels)
  │   └── LocalSTTCore (reusable platform-agnostic)
  │       ├── GroqService
  │       ├── VocabularyManager
  │       ├── ReplacementManager
  │       ├── HallucinationFilter
  │       ├── WAVEncoder
  │       └── KeychainHelper
  └── Views (RecordingView, LanguageBar, HistoryListView, VocabularyPanelView, etc.)
```

### Key Files by Purpose

#### Core Business Logic (LocalSTTCore)
| File | Purpose | Lines | Testable |
|------|---------|-------|----------|
| GroqService.swift | HTTP client, multipart/form-data, error handling | 170 | ✅ (10 tests) |
| VocabularyManager.swift | File I/O, prompt building, casing correction, usage tracking | 330 | ✅ (25 tests) |
| ReplacementManager.swift | Regex rules, text replacement, thread-safe storage | 200 | ✅ (12 tests) |
| HallucinationFilter.swift | Detects phantom Whisper phrases (50+ multilingual) | 70 | ✅ (16 tests) |
| WAVEncoder.swift | PCM to WAV encoding, RIFF header generation | 77 | ✅ (6+ tests) |
| TranscriptionResult.swift | Data model with formatting helpers | 50 | ✅ |
| ReplacementRule.swift | Data model with custom JSON decoding | 34 | ✅ |
| KeychainHelper.swift | Secure API key storage | 61 | Partial |

#### UI Views (LocalSTT)
| File | Purpose | Key Features |
|------|---------|--------------|
| RecordingView.swift | Main screen layout | History, language bar, record button, status messages |
| RecordButton.swift | Hold-to-record gesture | UILongPressGestureRecognizer, pulse animation, duration timer |
| WaveformView.swift | Real-time visualization | 40 animated bars, RMS-driven, jitter effect |
| LanguageBar.swift | Language selector | AUTO/EN/FR/中文, one-tap buttons |
| HistoryListView.swift | Searchable history | Compact + full modes, copy-to-clipboard, swipe-to-delete |
| VocabularyPanelView.swift | Vocabulary manager | Add/remove words, usage badges, 85-word limit |
| ReplacementPanelView.swift | Replacement rules | Add/remove rules, enable/disable toggle, 100-rule limit |
| SettingsView.swift | API key management | SecureField, eye toggle, test button |
| TranscriptionHistoryView.swift | History sheet | Clear All button, delegates to HistoryListView |
| ResultCard.swift | Result display | Copy button, metadata (lang, duration, processing time) |

#### Data Storage
| Location | Contents | Type | Persistence |
|----------|----------|------|-------------|
| Keychain | Groq API key | Secure string | Device-specific |
| UserDefaults | Language, history, replacements toggle | JSON/String | Device-specific |
| Application Support | vocabulary.txt, replacements.json, vocabulary_usage.json | Files | Device-specific |

### Feature Matrix

| Feature | Implementation | Limits | Language Support |
|---------|---|---|---|
| **Vocabulary** | VocabularyManager + regex casing | 85 words, 896 char prompt | All (case-sensitive) |
| **Replacements** | ReplacementManager + NSRegularExpression | 100 rules, case-insensitive | All (whole-word) |
| **Hallucination Filter** | HallucinationFilter static Set | 50+ phrases | EN, ZH, JA, FR |
| **History** | TranscriptionResult + UserDefaults | 100 items | All |
| **Auto-Paste** | UIPasteboard.general.string | Clipboard only | N/A |
| **Hotkeys** | Python backend only | N/A | N/A |

### Audio Pipeline Specs

| Parameter | Value |
|-----------|-------|
| Sample Rate | 16 kHz (Groq requirement) |
| Channels | 1 (mono) |
| Bit Depth | 16-bit signed PCM |
| Format | WAV with 44-byte RIFF header |
| Buffer Size | 4096 frames (~85ms at 48kHz) |
| Min Recording Duration | 0.3 seconds |
| RMS Normalization | ×5 multiplier (typical speech 0.01-0.3) |

### API Integration (Groq Whisper)

| Parameter | Value |
|-----------|-------|
| **Model** | whisper-large-v3-turbo |
| **Endpoint** | https://api.groq.com/openai/v1/audio/transcriptions |
| **Auth** | Bearer token (Keychain) |
| **Format** | multipart/form-data |
| **Fields** | model, response_format, language (opt), prompt (opt), file |
| **Response** | JSON {text, language?, duration?} |
| **Error Codes** | 401 = invalid key, other = HTTP error |

---

## Platform Compatibility

### iOS 17+ ✅
- @Observable (reactive state management)
- async/await (modern concurrency)
- AVAudioEngine (reliable audio)
- Accessibility features

### macOS 14+
- **LocalSTTCore**: 100% compatible (declared in Package.swift)
- **UI**: Not implemented (needs macOS-specific views + hotkeys)

### Deployment
- **Frameworks**: Foundation, SwiftUI, AVFoundation, Security (UIKit only for gestures)
- **Dependencies**: Zero external packages
- **Bundle Size**: ~5-10MB (app bundle)

---

## Important Notes for Developers

### 1. UILongPressGestureRecognizer Bridge
**File**: RecordButton.swift (lines 151-192)
- Uses UIViewRepresentable to bridge UIKit gesture
- Necessary because SwiftUI DragGesture(minimumDistance: 0) conflicts with scroll gestures
- Pragmatic workaround for reliable hold-to-record

### 2. Observable Mirrors
**File**: AppState.swift (lines 59-72)
- VocabularyManager and ReplacementManager are not @Observable
- Manual syncVocabulary() and syncReplacements() calls needed after mutations
- Alternative designs possible but add complexity

### 3. Vocabulary Ordering
- Words reordered by usage on every save
- Acceptable performance: max 85 words, O(n log n) sort
- Could optimize with caching if needed

### 4. Regex Template Escaping
**File**: VocabularyManager.swift (lines 317-320), ReplacementManager.swift (lines 186-190)
- NSRegularExpression interprets $0, $1, \, & as special chars
- Replacement text must escape: $ → \$, \ → \\, & → \&
- Prevents unintended variable substitution

### 5. Word Boundary Handling
- Pattern: \b...\b (NSRegularExpression ICU regex)
- Handles most English/European cases
- May differ from Python re for hyphenated words (not tested)

---

## Testing Strategy

### Covered (60+ Tests)
- ✅ Groq API multipart building, error handling, response decoding (10 tests)
- ✅ Hallucination phrase detection, case sensitivity, whitespace handling (16 tests)
- ✅ Vocabulary: prompt building, casing correction, word management, file I/O, usage tracking (25 tests)
- ✅ Replacement: rule management, regex compilation, enable/disable toggle (12 tests)
- ✅ WAV encoding, duration estimation
- ✅ TranscriptionResult formatting

### Not Covered (UI-level)
- ⚪ RecordButton interactions
- ⚪ HistoryListView search/filtering
- ⚪ Audio recording (AVAudioEngine integration)
- ⚪ Keychain operations (basic, low risk)

**Rationale**: Unit testing business logic is sufficient; SwiftUI UI testing adds little value vs maintenance burden.

---

## Known Limitations

1. **Groq API Only**: Backend supports OpenAI/Groq, iOS only implements Groq
2. **No Cloud Sync**: Vocabulary/replacements are device-local
3. **No Local Whisper**: iOS app requires internet (relies on Groq API)
4. **Single Audio File**: No batch transcription or streaming
5. **iOS Only UI**: macOS target declared in Package.swift but no macOS UI implementation

---

## Next Steps

### For Mac Architect
1. Read ios-analyst.md Section 15 ("Summary for Mac Architect")
2. Reuse LocalSTTCore directly (10 platform-agnostic modules)
3. Implement macOS-specific UI:
   - Menu bar icon + floating window
   - Keyboard hotkey via NSEvent.addGlobalMonitorForEvents
   - Auto-paste via CGWindowListCopyWindowInfo + AppleScript
4. Consider AVAudioEngine (same as iOS) vs local Whisper via whisper.cpp binding

### For Backend Team
1. Vocabulary system already ported to iOS (no sync needed yet)
2. Replacement rules already ported to iOS
3. Hallucination filtering already ported to iOS
4. Groq API is stateless—iOS and backend can coexist

---

## Report Metadata

| Field | Value |
|-------|-------|
| **Report File** | ios-analyst.md |
| **Total Lines** | 8,000+ |
| **Files Analyzed** | 30 Swift files (6 core, 10 views, 14 tests) |
| **Test Coverage** | 60+ unit tests |
| **Code Samples** | 50+ code snippets with line numbers |
| **Diagrams** | Architecture diagram, data flow, component hierarchy |
| **Time to Read** | 2-3 hours (full), 30 min (sections) |

---

**Generated by**: ios-analyst
**Reviewed by**: (team-lead)
**Status**: ✅ Ready for implementation teams
