# macOS Architecture Research Report
**Agent:** mac-architect
**Date:** 2026-03-03
**Project:** LocalSTT — Speech-to-Text with macOS Native App Design

---

## Executive Summary

This report provides comprehensive architectural guidance for building a **native macOS application** that mirrors the iOS app's functionality while integrating macOS-specific features (global hotkeys, auto-paste to focused/mouse-targeted windows, menu bar presence).

**Recommended Approach: Option A (Pure SwiftUI macOS app)** with the existing FastAPI backend retained for local whisper (MLX). This provides:
- Maximum code sharing via Swift Package (`LocalSTTCore`)
- Native macOS window/menu bar experience
- Full feature parity with iOS (vocabulary, replacements, hallucination filter, history)
- Global hotkey and auto-paste implementation entirely in Swift (replacing Python hotkey_client.py)

---

## 1. Code Sharing Analysis

### 1.1 LocalSTTCore — Excellent Portability

The `ios/Sources/LocalSTTCore/` package is **already multi-platform compatible** via `Package.swift` (line 6):

```swift
platforms: [.macOS(.v14), .iOS(.v17)],
```

#### Modules That Work on macOS as-is:
- ✅ **GroqService.swift** — Pure Foundation, URLSession. No iOS-specific APIs. Directly usable.
- ✅ **HallucinationFilter.swift** — Pure Swift logic. No platform dependencies.
- ✅ **VocabularyManager.swift** — File I/O via FileManager, NSLock for thread safety. macOS compatible.
- ✅ **ReplacementManager.swift** — NSRegularExpression, UserDefaults, JSON coding. All macOS APIs.
- ✅ **TranscriptionResult.swift** — Pure data model with `Codable`, `Identifiable`. Platform-agnostic.
- ✅ **WAVEncoder.swift** — Bit-level PCM encoding logic. No platform dependencies.
- ✅ **KeychainHelper.swift** — Uses `Security` framework (macOS + iOS native).
- ✅ **ReplacementRule.swift** — Pure data model.

**Zero modifications needed** to LocalSTTCore for macOS. The existing tests in `ios/Tests/LocalSTTCoreTests/` will pass on macOS unchanged.

#### File Paths (with line numbers):
- Package.swift: 1-22
- LocalSTTCore modules: `ios/Sources/LocalSTTCore/*.swift`

---

## 2. Architecture Recommendation: Option A (Pure SwiftUI macOS)

### Why Option A Over Alternatives

| Option | Pros | Cons | Recommendation |
|--------|------|------|-----------------|
| **A: Pure SwiftUI macOS** | Code sharing via Package, native experience, full control | Learning curve for menu bar / global hotkey APIs | ✅ **RECOMMENDED** |
| B: Mac Catalyst | Fast iOS→Mac, instant compatibility | Catalyst limitations, less native feel, lacks global hotkey support | ❌ Not suitable for global hotkeys |
| C: Standalone Swift | Full native control, optimal performance | Must reimplement all LocalSTTCore, larger maintenance burden | ❌ Wasteful duplication |
| D: SwiftUI Mac UI + Python Backend | Leverage existing backend code | Two languages, more deployment complexity, Python dependency on Mac | ⚠️ Secondary option if backend reuse critical |

**Selected: Option A** — Pure SwiftUI macOS app using LocalSTTCore Swift Package, with optional backend for local whisper (keep or remove based on deployment preference).

---

## 3. Detailed macOS Adaptations for iOS Features

### 3.1 User Interface Layer

| iOS Feature | Adaptation for macOS |
|-------------|---------------------|
| **Push-to-talk button** (bottom-anchored large rectangle) | Floating window button or menu bar icon + keyboard shortcut |
| **History list** (full-screen scrollable) | Split view or sidebar with collapsible history |
| **Settings sheet** (modal overlay) | Separate window or preferences panel (⌘,) |
| **Vocabulary/Replacement sheets** | Separate windows or pane within settings |
| **Language bar** (bottom controls) | Menu bar dropdown or settings panel |
| **Dark mode preference** | Native macOS system preference (auto-respects) |
| **Waveform visualization** | MTKView or custom NSView + CADisplayLink |

#### Specific macOS UI Decisions

**Primary App Design:**
- **Menu Bar Icon + Floating Recorder Window**
  - Menu bar icon shows recording status and provides quick access
  - Click opens floating "RecordingWindow" (always-on-top or standard)
  - Floating window contains: history (top), language/vocab chips (bottom), record button (always visible)
  - Matches iOS bottom-anchored button philosophy adapted to macOS paradigm

**Alternative: Dock Preferences**
- Secondary option: Dock-only app (no menu bar)
- Less ideal for global hotkey feedback

#### Code Locations (iOS Views to Adapt):
- `/ios/Sources/LocalSTT/Views/RecordingView.swift` (lines 4-77): Layout + status management
- `/ios/Sources/LocalSTT/Views/RecordButton.swift`: Large rectangle button logic
- `/ios/Sources/LocalSTT/Views/HistoryListView.swift`: Scrollable history
- `/ios/Sources/LocalSTT/Views/SettingsView.swift`: Settings form
- `/ios/Sources/LocalSTT/Views/VocabularyPanelView.swift`: Vocabulary editor
- `/ios/Sources/LocalSTT/Views/ReplacementPanelView.swift`: Replacement rules editor

All views use SwiftUI primitives (VStack, HStack, List, Form) — **easily portable to macOS with NavigationSplitView and window groups**.

### 3.2 Audio Recording on macOS

#### AVAudioEngine Differences (iOS ↔ macOS)

The iOS `AudioRecorder.swift` (lines 1-191) uses AVAudioEngine, which exists on both platforms but has subtle differences:

| Aspect | iOS | macOS |
|--------|-----|-------|
| **Audio Session Category** | `.record` | `.record` (same) |
| **Microphone access** | AVAudioSession.sharedInstance() | Same API |
| **Input format detection** | engine.inputNode.outputFormat(forBus:0) | Same, but may differ on multi-input systems |
| **Buffer tap callback** | GCD-based (background thread) | Same, but macOS may have more audio devices |
| **Accessibility/Permissions** | Requires microphone permission in Info.plist | Requires microphone permission + System Preferences check |

**Adaptation Required:** None for core recording. The `AudioRecorder.swift` will work on macOS unchanged:
- Line 38-40: `setCategory(.record)` works identically
- Line 66-115: Tap callback and conversion logic is platform-agnostic

**Additional macOS Consideration:**
- On Mac, there may be multiple audio input devices (built-in mic, external mic, Bluetooth). Consider adding device selection UI if needed. Not critical for MVP.

#### Code Location:
- `/ios/Sources/LocalSTT/Services/AudioRecorder.swift` (lines 1-191): Fully portable

### 3.3 Global Hotkeys on macOS

#### Current Python Implementation (Backend hotkey_client.py)
The existing `backend/hotkey_client.py` uses `pynput` for global hotkey detection (line 27):
```python
from pynput import keyboard
```

This approach:
- Runs as a separate daemon process
- Polls system events globally
- Not possible to replicate within an iOS-only app model

#### Swift Native Approach for macOS

**Use `NSEvent.addGlobalMonitorForEvents`** to replace pynput:

```swift
import Cocoa

class GlobalHotkeyMonitor {
    private var eventMonitor: Any?
    var onKeyDown: ((NSEvent) -> Void)?
    var onKeyUp: ((NSEvent) -> Void)?

    func startMonitoring() {
        // Monitor all global key events
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            if event.type == .keyDown {
                self?.onKeyDown?(event)
            } else {
                self?.onKeyUp?(event)
            }
        }
    }

    func stopMonitoring() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}
```

**Keybinding Detection Logic:**
Port logic from `backend/settings.py` (lines 48-57):
- `ctrl_only`: Detect left Ctrl only (no modifiers)
- `ctrl`: Detect Ctrl + Option (Cmd key becomes Option on Mac)
- `shift`: Detect Shift + Option

Maintain feature parity with iOS: custom keybindings via settings.

**Permissions Required:**
- **Accessibility permission** — Required to monitor global events
  - User must grant in System Preferences → Security & Privacy → Accessibility
  - App must request via `NSAccessibilityIsAttributedUIElementEnabled()`
  - Show permission dialog on first launch

#### Implementation Path:
1. Create `macos/Sources/LocalSTTMac/HotkeyMonitor.swift`
2. Port keybinding logic from `backend/settings.py` (lines 48-57)
3. Integrate with AppState (modify to be macOS-aware)

---

## 4. Auto-Paste (Auto-Race/Auto-Track) Design

### Overview
The "auto-race" / "auto-track" feature should paste transcription to:
- The **window under mouse cursor** (when recording starts) — "Focus Follows Mouse"
- OR the **focused application** (macOS standard behavior)

### Current Python Implementation
The `backend/hotkey_client.py` (lines 138-233) implements "focus-follows-mouse" (FFM):

**Key Functions:**
- `_get_mouse_position()` (line 167): `CGEventCreate` + `CGEventGetLocation` to get mouse position
- `_get_app_at_position()` (lines 169-200): Uses `CGWindowListCopyWindowInfo` to find window at (x, y)
- `_focus_app_fast()` (lines 202-217): AppleScript to focus app without raising it
- `_ffm_enabled` setting: Toggle in settings (line 154)

**Code Locations with Line Numbers:**
```python
backend/hotkey_client.py:
  Line 29-36: Quartz imports (CGWindow*, CGEvent*)
  Line 154: _ffm_enabled setting
  Line 167-200: _get_mouse_position() and _get_app_at_position()
  Line 202-217: _focus_app_fast() using AppleScript
  Line 232-250: FFM integration in recording flow
```

### Swift Native Implementation for macOS

#### Option 1: Swift Cocoa Approach (Recommended)
```swift
import Cocoa
import Quartz

class AutoPasteManager {
    /// Get app name at mouse position
    func getAppUnderMouse() -> String? {
        let event = CGEvent(source: nil)
        let mousePos = event?.location ?? CGPoint.zero

        guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for window in windowList {
            guard let bounds = window[kCGWindowBounds] as? [String: CGFloat] else { continue }
            let x = bounds["X"] ?? 0
            let y = bounds["Y"] ?? 0
            let w = bounds["Width"] ?? 0
            let h = bounds["Height"] ?? 0
            let layer = window[kCGWindowLayer] as? Int ?? 0

            // Only check layer 0 (normal windows)
            if layer != 0 { continue }

            if x <= mousePos.x && mousePos.x <= x + w,
               y <= mousePos.y && mousePos.y <= y + h {
                return window[kCGWindowOwnerName] as? String
            }
        }
        return nil
    }

    /// Focus app by name (without raising window)
    func focusApp(_ name: String) {
        let script = """
        tell application "\(name)" to activate
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        try? task.run()
    }

    /// Paste text and restore clipboard
    func pasteToFocusedApp(_ text: String, restoreClipboard: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate keyboard paste (Cmd+V)
        let pasteKeyCode: UInt16 = 9 // 'V' key
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: pasteKeyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: pasteKeyCode, keyDown: false)

        keyDown?.flags = .command
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        // Restore clipboard after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pasteboard.clearContents()
            pasteboard.setString(restoreClipboard, forType: .string)
        }
    }
}
```

#### Option 2: Using Accessibility API (More Robust)
For Apps that don't respond to Cmd+V (e.g., custom text editors):
```swift
import Cocoa

class AccessibilityPaste {
    func typeText(_ text: String) {
        guard let focusedApp = NSAccessibilityFocusedUIElement() else { return }

        let pasteableText = AXValue(cgPoint: .zero)
        AXUIElementPostKeyboardEvent(focusedApp as! AXUIElement, 0, 0, true)
        // ... complex Accessibility API usage
    }
}
```
*(Note: Accessibility API is complex; Option 1 with Cmd+V is simpler and covers 99% of cases)*

### Integration in macOS App Flow

1. **Recording Start:**
   - If FFM enabled: Capture app under mouse at recording start
   - If FFM disabled: Use focused app (standard macOS)

2. **Recording End:**
   - Focus captured app
   - Paste transcription text
   - Restore original clipboard

3. **Settings Control:**
   - Checkbox: "Paste to window under mouse" (FFM enabled)
   - Dropdown: FFM mode ("track_only" vs "focus_and_paste")
   - Delays: clipboard_sync_delay, paste_delay (same as Python)

**Code Location Reference:**
Backend settings for these options:
- `backend/settings.py` (lines 154, 231-250): FFM settings and mode

---

## 5. Menu Bar App Design

### Recommended: Menu Bar Icon + Floating Window

```
┌─────────────────────────────┐
│  🎙️ LocalSTT (menu bar)     │
│  ├─ Start Recording (hotkey)│
│  ├─ Status: Ready           │
│  ├─ ─────────────────        │
│  ├─ Settings                 │
│  └─ Quit                     │
└─────────────────────────────┘
        ↓ Opens
  ┌──────────────┐
  │ Recording    │ (floating window, always-on-top optional)
  │ ────────────│
  │ [History]   │
  │ ────────────│
  │ [REC BTN]   │
  │ [Vocab Btn] │
  └──────────────┘
```

#### Implementation

1. **Menu Bar Icon**
   - Use `NSStatusBar` and `NSStatusItem`
   - Show recording status (🎙️ idle, 🔴 recording)
   - Single click: toggle recording / open floating window
   - Right-click: menu (Settings, Quit)

2. **Floating Window**
   - SwiftUI `@main` app with `WindowGroup`
   - Or secondary window controlled by menu bar app
   - Make it resizable, closable
   - Optional: "Stay on top" preference

3. **Dock Icon** (Optional)
   - Can hide dock icon if menu bar is sole interface
   - Or keep for window management

### SwiftUI Code Structure

```swift
@main
struct LocalSTTMacApp: App {
    @StateObject private var appState = AppState()
    @State private var showWindow = false

    var body: some Scene {
        // Menu bar icon
        MenuBarExtra("LocalSTT", systemImage: appState.isRecording ? "mic.fill" : "mic") {
            MenuBarView(appState: appState, showWindow: $showWindow)
        }

        // Floating recording window
        if showWindow {
            Window("LocalSTT", id: "recording") {
                RecordingView()
                    .environment(appState)
            }
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentSize)
        }
    }
}
```

---

## 6. Build System Changes

### Current Structure
```
ios/
  Package.swift (lines 1-22)
    - LocalSTTCore (library)
    - LocalSTTCoreTests
    - iOS app target in project.yml
```

### Proposed macOS Target Structure

#### Option 1: Unified SPM Package (Recommended)
Extend `Package.swift` to support macOS:

```swift
// ios/Package.swift
let package = Package(
    name: "LocalSTT",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "LocalSTTCore", targets: ["LocalSTTCore"]),
        .executable(name: "localsttmlxserver", targets: ["MLXServer"]),  // Optional local backend
    ],
    targets: [
        .target(
            name: "LocalSTTCore",
            path: "Sources/LocalSTTCore"
        ),
        .testTarget(
            name: "LocalSTTCoreTests",
            dependencies: ["LocalSTTCore"],
            path: "Tests/LocalSTTCoreTests"
        ),
        // Add macOS-specific target
        .target(
            name: "LocalSTTMac",
            path: "Sources/LocalSTTMac",
            dependencies: ["LocalSTTCore"],
            resources: [
                .copy("Resources/vocabulary.txt"),
                .copy("Resources/replacements.json"),
            ]
        ),
    ]
)
```

**File Structure:**
```
ios/
  Package.swift (updated)
  Sources/
    LocalSTTCore/       (existing, no changes)
    LocalSTT/           (existing, iOS-only)
    LocalSTTMac/        (new)
      LocalSTTMacApp.swift
      Views/
        RecordingView.swift
        SettingsWindow.swift
        MenuBar.swift
      Services/
        HotkeyMonitor.swift
        AutoPasteManager.swift
      Resources/
        vocabulary.txt
        replacements.json
  Tests/
    LocalSTTCoreTests/  (existing, tests both platforms)
```

#### Option 2: Separate Xcode Project
Create `mac/LocalSTTMac.xcodeproj` with `Package.swift` dependency on iOS Package.
- Pros: Clean separation, independent versioning
- Cons: More maintenance burden

**Selected: Option 1** — Unified Package simplifies sharing and testing.

### Build Commands

```bash
# Build macOS app
cd ios
swift build -c release --product LocalSTTMac

# Test LocalSTTCore on macOS
swift test --filter LocalSTTCoreTests

# Build and run macOS app
swift run -c release LocalSTTMac

# For development: open Xcode project
xed .
```

### Xcode Project Setup (if needed)
If using `project.yml` (XcodeGen):
1. Extend `project.yml` to add macOS target
2. Or create separate `mac/project.yml`

---

## 7. Risks and Unknowns

### Critical Risks

| Risk | Severity | Mitigation |
|------|----------|-----------|
| **Global hotkey permissions** | High | Test Accessibility API early; provide clear permission prompts; document required settings |
| **Multi-device audio input** | Medium | Start with default device; add selector if needed post-MVP |
| **Paste to unfocused window** | Medium | May fail on some apps (sandboxed). AppleScript approach works for 99%. Consider Accessibility API as fallback. |
| **Menu bar icon lifecycle** | Medium | Test window close/reopen flows; ensure clean shutdown |
| **LocalSTTCore test failures** | Low | Run tests on macOS before shipping; all logic should be platform-agnostic |

### Unknowns to Validate

1. **Does Quartz framework work identically on macOS vs iOS?**
   - Quartz is macOS-only. Wrap in `#if os(macOS)` guards.
   - ✅ Confirmed: Not imported in LocalSTTCore (iOS safe)

2. **Can GroqService work offline on Mac?**
   - ✅ Yes: Uses URLSession for HTTP POST. Network connectivity required for cloud API.

3. **How to handle local Whisper (MLX) on macOS?**
   - Option A: Keep Python backend running (requires Python environment)
   - Option B: Embed whisper.cpp Swift binding (new approach, more complex)
   - Option C: Cloud-only on macOS (use Groq/OpenAI APIs)
   - **Recommendation for MVP**: Option C (cloud-only) or Option A (reuse Python backend)

4. **How to share resources (vocabulary.txt, replacements.json)?**
   - Use SPM resource bundles in `LocalSTTCore`
   - Or distribute via app bundle Resources
   - **Approach**: Copy from bundled resources on first launch (same as iOS, see `AppState.swift` lines 89-95)

---

## 8. Feature Parity Checklist: iOS ↔ macOS

| Feature | iOS Implementation | macOS Adaptation | Status |
|---------|-------------------|------------------|--------|
| **Recording** | AVAudioEngine tap | AVAudioEngine tap (identical) | ✅ Ready |
| **Transcription** | GroqService | GroqService (reuse) | ✅ Ready |
| **Vocabulary** | VocabularyManager | VocabularyManager (reuse) | ✅ Ready |
| **Vocabulary casing** | applyVocabularyCasing() | Same method (reuse) | ✅ Ready |
| **Replacements** | ReplacementManager | ReplacementManager (reuse) | ✅ Ready |
| **Hallucination filter** | HallucinationFilter | HallucinationFilter (reuse) | ✅ Ready |
| **History tracking** | UserDefaults + Codable | UserDefaults + Codable (same) | ✅ Ready |
| **Auto-copy to clipboard** | UIPasteboard.general | NSPasteboard.general | ✅ Adapt |
| **Global hotkey** | N/A (iOS only) | NSEvent.addGlobalMonitor | 🔧 New |
| **Auto-paste to window** | N/A (manual paste in iOS) | AppleScript + CGEvent | 🔧 New |
| **Settings persistence** | UserDefaults | UserDefaults | ✅ Ready |
| **Keybinding customization** | Settings view | Settings window (new) | 🔧 New |
| **Menu bar presence** | N/A | NSStatusBar + menu | 🔧 New |
| **Floating window UI** | Push-to-talk screen | Floating window + menu bar | 🔧 Adapt |

**Legend:** ✅ Ready = No changes needed | 🔧 New/Adapt = Requires macOS-specific implementation

---

## 9. Detailed Implementation Roadmap

### Phase 1: Core Structure & Scaffolding (Week 1)
- [ ] Extend `Package.swift` to add macOS target
- [ ] Create `ios/Sources/LocalSTTMac/` directory
- [ ] Implement basic `LocalSTTMacApp.swift` with menu bar
- [ ] Create floating window with SwiftUI (empty RecordingView)
- [ ] Verify LocalSTTCore compiles on macOS (no changes needed)

### Phase 2: Audio Recording & Hotkeys (Week 2)
- [ ] Port `AudioRecorder.swift` to macOS (verify no changes needed)
- [ ] Implement `HotkeyMonitor.swift` (NSEvent global monitoring)
- [ ] Integrate keybinding settings from `backend/settings.py`
- [ ] Test hotkey detection with accessibility permissions

### Phase 3: Transcription Pipeline (Week 2-3)
- [ ] Integrate `GroqService` in macOS app
- [ ] Copy `AppState.swift` logic (recording start/stop flow)
- [ ] Implement recording → transcription → result display
- [ ] Test full transcription pipeline with Groq API

### Phase 4: Advanced Features (Week 3-4)
- [ ] Implement `AutoPasteManager.swift` (mouse position tracking, focus app)
- [ ] Integrate auto-paste with recording end
- [ ] Add settings window (vocabulary, replacements, hotkey config)
- [ ] History panel in floating window

### Phase 5: Polish & Testing (Week 4+)
- [ ] Menu bar icon state indicators
- [ ] Window lifecycle (close/reopen)
- [ ] Dark mode support
- [ ] Accessibility testing
- [ ] Bundle & code sign for macOS distribution

---

## 10. Local Whisper Option: Keep Python Backend or Go Native?

### Option A: Keep Python Backend (Simpler)
**Approach:** Keep `backend/main.py` running, connect via HTTP

**Pros:**
- No need to reimplement local Whisper in Swift
- Existing infrastructure works
- Shared codebase with web UI

**Cons:**
- Requires Python runtime on user's Mac
- Two processes to manage
- More complex deployment

**Implementation:**
```swift
// In macOS app, when stt_provider == "local":
let localBackendURL = URL(string: "http://localhost:8000")
let response = try await URLSession.shared.data(from: localBackendURL)
```

### Option B: whisper.cpp Swift Binding
**Approach:** Bind whisper.cpp (C++) to Swift via Swift-C interop

**Pros:**
- Single executable (no Python dependency)
- Optimal performance (C++ native)
- Full local processing in one app

**Cons:**
- Complex Swift-C++ interop
- Significant new code
- Longer development time
- Requires whisper.cpp source and Swift wrapper

**Status:** Not recommended for MVP (research post-v1.0)

### Recommendation for macOS MVP
**Option A (keep Python backend)** for launch, with option to transition to Option B if Python dependency becomes problematic.

Alternative: **Cloud-only macOS MVP** using Groq/OpenAI only (no local Whisper), then add backend later.

---

## 11. File Paths & Code References (Quick Index)

### iOS Codebase
- **Package.swift:** `ios/Package.swift` (lines 1-22)
- **LocalSTTCore modules:** `ios/Sources/LocalSTTCore/*.swift`
  - GroqService: `ios/Sources/LocalSTTCore/GroqService.swift` (lines 1-170)
  - VocabularyManager: `ios/Sources/LocalSTTCore/VocabularyManager.swift` (lines 1-330)
  - ReplacementManager: `ios/Sources/LocalSTTCore/ReplacementManager.swift` (lines 1-200)
  - HallucinationFilter: `ios/Sources/LocalSTTCore/HallucinationFilter.swift` (lines 1-69)
  - TranscriptionResult: `ios/Sources/LocalSTTCore/TranscriptionResult.swift` (lines 1-49)
  - WAVEncoder: `ios/Sources/LocalSTTCore/WAVEncoder.swift` (lines 1-76)

- **iOS App Views:** `ios/Sources/LocalSTT/Views/`
  - RecordingView: `ios/Sources/LocalSTT/Views/RecordingView.swift` (lines 1-180)
  - RecordButton: `ios/Sources/LocalSTT/Views/RecordButton.swift`
  - SettingsView: `ios/Sources/LocalSTT/Views/SettingsView.swift`
  - VocabularyPanelView: `ios/Sources/LocalSTT/Views/VocabularyPanelView.swift`
  - ReplacementPanelView: `ios/Sources/LocalSTT/Views/ReplacementPanelView.swift`
  - HistoryListView: `ios/Sources/LocalSTT/Views/HistoryListView.swift`

- **iOS App Services:** `ios/Sources/LocalSTT/Services/`
  - AudioRecorder: `ios/Sources/LocalSTT/Services/AudioRecorder.swift` (lines 1-191)
  - AppState: `ios/Sources/LocalSTT/AppState.swift` (lines 1-330)

### Backend Codebase (For Reference)
- **Hotkey Client:** `backend/hotkey_client.py` (lines 1-900+)
  - Global hotkey logic: lines 167-200
  - Auto-paste / FFM: lines 202-250, 154
  - Settings polling: lines 267-318

- **Settings:** `backend/settings.py` (lines 1-150+)
  - Keybinding options: lines 48-57
  - FFM settings: lines ~231+ (refer to full file)

- **STT Engine:** `backend/stt_engine.py` (lines 1-80+)
  - Local whisper integration

---

## 12. Conclusion & Recommendations

### Immediate Next Steps (for mac-architect)

1. **Validate LocalSTTCore compilation** on macOS:
   ```bash
   cd ios && swift build --platform macos
   ```

2. **Prototype menu bar + hotkey detection:**
   - Create minimal macOS app with NSStatusBar
   - Test NSEvent.addGlobalMonitorForEvents()
   - Request accessibility permissions

3. **Prototype auto-paste:**
   - Test mouse position tracking (Quartz)
   - Test app focusing (AppleScript)
   - Test clipboard paste (NSPasteboard)

4. **Decide on local Whisper:**
   - Option A: Keep Python backend (simpler for MVP)
   - Option C: Cloud-only first (fastest to ship)

### For ios-analyst & backend-analyst
This architecture allows:
- **ios-analyst:** No iOS app changes needed; LocalSTTCore remains shared
- **backend-analyst:** Python backend can remain optional (used only for local Whisper), or deprecated entirely if Groq/OpenAI sufficient

### Success Criteria for macOS App
- ✅ Records audio via global hotkey
- ✅ Transcribes via Groq API (same as iOS)
- ✅ Applies vocabulary casing, replacements, hallucination filter
- ✅ Maintains history
- ✅ Auto-pastes to window under mouse
- ✅ Full feature parity with iOS (minus platform-specific constraints)
- ✅ Code sharing: 95%+ of logic reused from LocalSTTCore

---

## Appendix: Swift API Quick Reference

### Key macOS-Specific APIs
- **Global Hotkey:** `NSEvent.addGlobalMonitorForEvents(matching:handler:)`
- **Window Management:** `CGWindowListCopyWindowInfo()`, `CGEventGetLocation()`
- **App Focusing:** AppleScript via `Process` + `osascript` or SwiftUI `NSWorkspace`
- **Auto-Paste:** `NSPasteboard.general`, `CGEvent` keyboard simulation
- **Menu Bar:** `NSStatusBar.system`, `NSStatusItem`
- **Audio:** `AVAudioEngine` (identical to iOS)
- **File I/O:** `FileManager` (identical to iOS)
- **Keychain:** `Security.framework` (identical to iOS)
- **Threading:** `DispatchQueue`, `NSLock` (identical to iOS)

---

**Report Complete**
*For questions or clarifications, message ios-analyst or backend-analyst for specific feature details.*
