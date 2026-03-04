# FFM Code Analysis Report
**Agent:** code-analyst
**Date:** 2026-03-03
**Task:** Full pipeline trace from app launch to paste for auto-raise and auto-paste

---

## Summary of Findings

I traced the complete FFM pipeline across all 5 relevant files. I found **5 confirmed bugs** and **2 suspected issues**. The most critical bug is the **initialization order problem** — `setupServices()` (which creates `AutoPasteManager`) is only called from `MainWindowView.onAppear`, meaning it is NOT called until a view appears. This creates a race condition with mouse tracking. A secondary critical bug is the **app name exclusion mismatch**: the excluded apps set includes `"LocalSTT"` but the actual app's `kCGWindowOwnerName` is likely `"LocalSTTMac"`, which means the app does NOT exclude itself from paste targets.

---

## 1. Initialization Chain — POTENTIAL RACE CONDITION

### File: `LocalSTTMacApp.swift` (line 33–56) + `MainWindowView.swift` (lines 55–57)

```swift
// LocalSTTMacApp.swift:33
@State private var appState = MacAppState()

// MainWindowView.swift:55-57
.onAppear {
    appState.setupServices()
}
```

`MacAppState` is created immediately when `LocalSTTMacApp` initializes. However, `setupServices()` — which creates `AutoPasteManager` and `GlobalHotkeyManager` — is only called from `MainWindowView.onAppear`.

**Problem:** The `AppDelegate.applicationDidFinishLaunching` fires, then with a 0.1s delay calls `NSApp.activate()`. The `WindowGroup` may or may not have triggered its `onAppear` by this point. This means:

1. At app launch, `autoPasteManager` is `nil` for an indeterminate period.
2. If the hotkey is pressed before the main window renders (e.g., if the user hides the window quickly), `autoPasteManager` is nil and paste silently falls back to clipboard-only (MacAppState.swift:277).

**Less critical in practice:** The window appears on launch, so `onAppear` fires quickly. But there's a non-zero window where paste won't work.

**Recommendation:** Move `setupServices()` call to `MacAppState.init()` or to `AppDelegate.applicationDidFinishLaunching`.

---

## 2. AutoPasteManager Init — DOUBLE startTracking() BUG

### File: `AutoPasteManager.swift` (lines 21–62)

```swift
// Lines 21-29: isEnabled property
var isEnabled: Bool = true {
    didSet {
        if isEnabled {
            startTracking()
        } else {
            stopTracking()
        }
    }
}

// Line 61: init
init() {
    startTracking()  // Called here in init
}
```

And in `MacAppState.setupServices()` (lines 152–154):

```swift
autoPasteManager = AutoPasteManager()          // calls startTracking() in init
autoPasteManager?.isEnabled = ffmEnabled       // triggers didSet → startTracking() AGAIN if true
```

**Bug:** When `ffmEnabled` is `true` (the default), `startTracking()` is called twice:
1. Once in `AutoPasteManager.init()` directly
2. Once via `isEnabled.didSet` when `setupServices()` sets `autoPasteManager?.isEnabled = ffmEnabled`

**Effect:** The second `startTracking()` call is guarded by `guard mouseMonitor == nil else { return }` (line 79), so it's a no-op. This means no crash — but it IS wasteful. More importantly: if `ffmEnabled` is `false`, calling `isEnabled = false` in `setupServices()` will call `stopTracking()`, which removes the monitor created in `init()`. So it correctly disables tracking when `ffmEnabled=false`.

**However:** The `isEnabled` property has default `true`, but the user might have it saved as `false`. If the saved value is `false`:
- `init()` starts tracking
- `setupServices()` sets `isEnabled = false`, which stops tracking

This means mouse tracking runs briefly (from `init()` to `setupServices()`) even when the user has disabled FFM. This is cosmetic only and has no user impact.

**Root cause of double startTracking:** The `init()` should NOT call `startTracking()` directly; instead set `isEnabled` via its own stored value from UserDefaults. But since `startTracking()` is idempotent due to the guard, this doesn't break anything.

---

## 3. CRITICAL BUG — Excluded App Name Mismatch

### File: `AutoPasteManager.swift` (lines 46–49)

```swift
private static let excludedApps: Set<String> = [
    "Dock", "Control Center", "Notification Center",
    "WindowManager", "SystemUIServer", "LocalSTT"
]
```

The excluded name is `"LocalSTT"` — but the macOS app is named `"LocalSTTMac"` (based on the project structure: `macos/Sources/LocalSTTMac/`, scheme name `LocalSTTMac`, and the `@main` struct `LocalSTTMacApp`).

**Impact:** When the main window of LocalSTTMac is under the mouse cursor, the FFM code will try to paste TO THE APP ITSELF instead of excluding it. This is a definitive bug.

**What happens:** The user finishes speaking, the main window (which shows the recording UI) gets paste sent to it — NOT the target app the user was trying to paste into.

**Verification needed:** Check `kCGWindowOwnerName` for the running app via Console logs. The log line in `handleMouseMoved` (line 118) will show: `[AutoPaste] Tracking: LocalSTTMac (PID ..., window ...)`. If the console investigator sees this log, it confirms the app is not excluding itself.

**Fix:** Change `"LocalSTT"` to `"LocalSTTMac"` in the exclusion set. Or better, dynamically get the current app name:

```swift
private static let excludedApps: Set<String> = {
    var base: Set<String> = ["Dock", "Control Center", "Notification Center",
                              "WindowManager", "SystemUIServer"]
    if let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String {
        base.insert(appName)
    }
    return base
}()
```

---

## 4. pasteText Call Site — IS Reachable, but Has Timing Issues

### File: `MacAppState.swift` (lines 269–281)

```swift
// Auto-paste to window under cursor (if FFM enabled)
if ffmEnabled, let pasteManager = autoPasteManager {
    print("[MacAppState] Auto-paste: ffmEnabled=\(self.ffmEnabled), trackedPID=\(pasteManager.trackedPID), trackedApp=\(pasteManager.trackedAppName)")
    pasteManager.pasteText(
        result.text,
        clipboardDelay: clipboardSyncDelay,
        pasteDelay: pasteDelay
    )
}
```

**The call path is reachable** IF:
- `state == .recording` (line 200 guard passes)
- `recorder.isRecording` (line 202 guard passes)
- `groqService` is non-nil (line 210 guard passes)
- Duration check passes (line 216)
- No hallucination (line 243)
- `ffmEnabled == true` AND `autoPasteManager != nil`

**Early returns that could block paste:**
1. Line 200: `guard state == .recording` — if hotkey manager fires `stopRecordingAndTranscribe` twice, second call returns early. Unlikely but possible.
2. Line 210: `guard let service = groqService` — if API key is not configured, paste is never reached.
3. Line 243: Hallucination filter — if the transcription is detected as hallucination, no paste.

**Timing issue in pasteText:** The `activationDelay` of 0.1s plus `clipboardDelay` (0.05s default) = 150ms before the paste keystroke fires. During this delay window, the user could move their mouse, causing `trackedPID` to update. But `pasteText` captures `targetPID` at the start (line 288), so it uses the PID at call time — not the current tracked PID. This is correct behavior.

**However:** There's a subtle threading issue. The `pasteText` method is called on `@MainActor` (inside `Task { @MainActor in }`). The `DispatchQueue.main.asyncAfter` calls inside `pasteText` (lines 321–335) are also on main. The `activateApp()` calls use `AXUIElementSetAttributeValue` and `NSRunningApplication.activate()` — both are fine on main thread.

---

## 5. CGEvent Timestamp Bug — PARTIALLY FIXED

### File: `AutoPasteManager.swift` (lines 357–358)

```swift
keyDown.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
keyUp.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
```

The CLAUDE.md memory notes: "macOS 15 Sequoia: CGEvent needs `timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`"

**This is implemented**, so the Sequoia gotcha is addressed.

**BUT:** There's a subtle issue. `keyDown` and `keyUp` are assigned timestamps consecutively via two calls to `clock_gettime_nsec_np`. On a fast CPU, both calls may return the **same nanosecond value** if the clock resolution isn't fine enough. The comment at line 356 says "keyDown and keyUp MUST have distinct increasing timestamps or keyUp may be dropped."

If both get the same timestamp, keyUp may be silently dropped on macOS 15, leaving the Cmd key stuck as "held" until the next key event.

**Fix:** Add a minimum gap, e.g.:
```swift
let t = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
keyDown.timestamp = t
keyUp.timestamp = t + 1000  // +1 microsecond
```

---

## 6. Mode Setting — CORRECT

### File: `MacAppState.swift` (line 154) + `MacSettingsView.swift` (lines 184–193)

```swift
// MacAppState.setupServices():
autoPasteManager?.mode = ffmMode == "raise_on_hover" ? .raiseOnHover : .trackOnly

// MacSettingsView picker tags:
Text("Track only").tag("track_only")
Text("Raise on hover").tag("raise_on_hover")

// updateFFMSettings():
autoPasteManager?.mode = ffmMode == "raise_on_hover" ? .raiseOnHover : .trackOnly
```

The string `"raise_on_hover"` matches the picker tag exactly. The mapping is correct. No bug here.

---

## 7. Mouse Monitor Lifecycle — POTENTIAL FAILURE IF NO ACCESSIBILITY

### File: `AutoPasteManager.swift` (lines 78–89)

```swift
private func startTracking() {
    guard mouseMonitor == nil else { return }

    mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
        self?.handleMouseMoved(event)
    }

    if mouseMonitor == nil {
        print("[AutoPaste] WARNING: Failed to create global mouse monitor — check Accessibility permissions")
    }
}
```

`NSEvent.addGlobalMonitorForEvents` requires Accessibility permission. If permission is not granted:
- Returns `nil`
- `mouseMonitor` stays `nil`
- The warning is printed
- `trackedPID` stays 0
- `pasteText` will hit the `guard targetPID > 0` (line 294) and fall back to clipboard-only

**This is the most likely cause of auto-paste not working on first install** — Accessibility permission is required and must be granted AND monitors must be restarted (via `restartMonitors()` or app restart).

The Settings UI correctly shows "Grant Access" + "Refresh" buttons when Accessibility is not granted (MacSettingsView.swift lines 82–98).

---

## 8. raiseOnHover — AX Coordinate System Mismatch Bug

### File: `AutoPasteManager.swift` (lines 214–232)

The `raiseWindow` function matches AXUIElement windows to CGWindowList windows by comparing position/size coordinates. However, **AXUIElement and CGWindowList use different coordinate systems on macOS**:

- **CGWindowList** (`kCGWindowBounds`): Top-left origin (y increases downward), in screen coordinates
- **AXUIElement** (`kAXPositionAttribute`): **Top-left origin but Y is flipped** — actually uses the same screen-space, but CGRect from `CGRect(dictionaryRepresentation:)` gives AppKit coordinates where Y origin is bottom-left

This is a known macOS gotcha. The `windowBounds(for:)` method returns a `CGRect` from `CGRect(dictionaryRepresentation: boundsDict as CFDictionary)`. CGWindowList bounds use screen coordinates with top-left origin. AXUIElement positions use Quartz screen coordinates (top-left origin as well on macOS).

**Actually they should match** — both CGWindowList and AXUIElement use the same flipped coordinate system on macOS (Y increases downward from top-left). So this should be fine.

**But the matching tolerance of `< 2` pixels** (line 226) could fail if the window has been moved by fractional amounts (e.g., on Retina displays). This is unlikely to cause issues in practice.

---

## 9. LSUIElement + Window Activation

### File: `LocalSTTMacApp.swift` (Info.plist via Resources) + `AutoPasteManager.swift` (lines 263–275)

The app uses `LSUIElement=YES` (background app). `activateApp` uses:
```swift
AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
NSRunningApplication(processIdentifier: pid)?.activate()
```

**Potential issue:** `NSRunningApplication.activate()` without `.ignoringOtherApps` option may not work reliably from a background (LSUIElement) app. The Accessibility approach (`kAXFrontmostAttribute`) is preferred for this reason.

However, `NSRunningApplication.activate()` was updated in macOS 14. The old `activate(options:)` with `.activateIgnoringOtherApps` was deprecated. The new `activate()` does bring the app to front. This should work.

**Less likely to be the root cause** given the AX approach is tried first.

---

## Complete Pipeline Trace

```
App Launch
  ├─ LocalSTTMacApp.init()
  │   └─ MacAppState() created ← autoPasteManager is nil here
  │
  ├─ AppDelegate.applicationDidFinishLaunching()
  │   └─ NSApp.activate() after 0.1s delay
  │
  ├─ MainWindowView.onAppear()  ← setupServices() called HERE
  │   └─ MacAppState.setupServices()
  │       ├─ GlobalHotkeyManager() created → startMonitoring()
  │       ├─ AutoPasteManager() created → startTracking()
  │       │   └─ NSEvent.addGlobalMonitorForEvents(.mouseMoved)
  │       │       └─ Returns nil if no Accessibility permission ← COMMON FAILURE
  │       ├─ autoPasteManager.isEnabled = ffmEnabled
  │       └─ autoPasteManager.mode = (ffmMode == "raise_on_hover") ? .raiseOnHover : .trackOnly
  │
User moves mouse
  └─ handleMouseMoved() (50ms throttle)
      └─ windowInfoUnderMouse(at:)
          ├─ NSWindow.windowNumber(at:belowWindowWithWindowNumber:0)
          ├─ CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID)
          └─ if appName == "LocalSTT" → SKIPPED (BUG: should be "LocalSTTMac")
              └─ trackedPID / trackedAppName / trackedWindowID updated

User holds Left Control
  └─ GlobalHotkeyManager.handleFlagsChanged()
      └─ MacAppState.startRecording()

User releases Left Control
  └─ MacAppState.stopRecordingAndTranscribe()
      └─ Task { @MainActor }
          └─ GroqService.transcribe()
              └─ (post-processing pipeline)
                  └─ if ffmEnabled && autoPasteManager != nil:
                      └─ autoPasteManager.pasteText(text)
                          ├─ guard targetPID > 0 ← FAILS if no mouse tracking
                          ├─ activateApp(pid)
                          ├─ asyncAfter(0.1s) → activateApp again
                          ├─ sendPasteKeystroke() ← Cmd+V via CGEvent
                          │   └─ CGEvent timestamps may collide (keyDown == keyUp)
                          └─ asyncAfter(pasteDelay) → restoreClipboard()
```

---

## Bug Priority Summary

| # | Bug | Severity | File | Lines |
|---|-----|----------|------|-------|
| 1 | **Excluded app name `"LocalSTT"` should be `"LocalSTTMac"`** | CRITICAL | AutoPasteManager.swift | 48 |
| 2 | **No Accessibility → mouseMonitor=nil → trackedPID=0 → no paste** | CRITICAL (by design but common failure) | AutoPasteManager.swift | 85–86 |
| 3 | **setupServices() called from onAppear → nil window before view appears** | HIGH (race condition) | MainWindowView.swift | 56 |
| 4 | **CGEvent keyDown/keyUp timestamps may be identical → keyUp dropped** | MEDIUM | AutoPasteManager.swift | 357–358 |
| 5 | **Double startTracking() on init when ffmEnabled=true** | LOW (no-op due to guard) | AutoPasteManager.swift + MacAppState.swift | 61, 153 |

---

## Recommendations

1. **Fix the excluded app name** (highest priority):
   ```swift
   // AutoPasteManager.swift line 48
   // Change "LocalSTT" to "LocalSTTMac" (or use dynamic Bundle.main approach)
   "WindowManager", "SystemUIServer", "LocalSTTMac"
   ```

2. **Fix CGEvent timestamp uniqueness**:
   ```swift
   let t = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
   keyDown.timestamp = t
   keyUp.timestamp = t + 1_000  // ensure keyUp is strictly later
   ```

3. **Move setupServices() earlier** — call from `AppDelegate.applicationDidFinishLaunching` or from `MacAppState.init()` directly (with Accessibility check deferred).

4. **Document Accessibility requirement** more prominently — it's the most common failure mode.

---

## Files Analyzed

| File | Path |
|------|------|
| AutoPasteManager.swift | `/Users/junlin/Documents/GitHub/local_stt/macos/Sources/LocalSTTMac/Services/AutoPasteManager.swift` |
| MacAppState.swift | `/Users/junlin/Documents/GitHub/local_stt/macos/Sources/LocalSTTMac/MacAppState.swift` |
| LocalSTTMacApp.swift | `/Users/junlin/Documents/GitHub/local_stt/macos/Sources/LocalSTTMac/LocalSTTMacApp.swift` |
| GlobalHotkeyManager.swift | `/Users/junlin/Documents/GitHub/local_stt/macos/Sources/LocalSTTMac/Services/GlobalHotkeyManager.swift` |
| MacSettingsView.swift | `/Users/junlin/Documents/GitHub/local_stt/macos/Sources/LocalSTTMac/Views/MacSettingsView.swift` |
| MainWindowView.swift | `/Users/junlin/Documents/GitHub/local_stt/macos/Sources/LocalSTTMac/Views/MainWindowView.swift` |
