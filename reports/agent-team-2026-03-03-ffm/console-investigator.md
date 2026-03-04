# Console Investigator Report: LocalSTTMac FFM/AutoPaste Debugging

**Date:** 2026-03-03
**App:** LocalSTTMac (PID 44383 initial, PID 52626 after rebuild with os.Logger)
**Binary:** `/Users/junlin/Library/Developer/Xcode/DerivedData/LocalSTTMac-euckjlkuzpbsjkepqllxhbqbaklu/Build/Products/Debug/LocalSTTMac.app/Contents/MacOS/LocalSTTMac`
**Bundle ID:** `com.localSTT.mac`

---

## Executive Summary

**Root cause confirmed with os.Logger evidence:** Accessibility permission is DENIED at runtime (error `-25211` = `kAXErrorAPIDisabled`) due to ad-hoc code signature mismatch. The mouse tracking monitor DOES work (surprising — despite kTCCServiceListenEvent denial), but ALL AXUIElement calls fail, making auto-raise and auto-paste non-functional.

**Key findings:**
1. Mouse tracking starts successfully (`NSEvent.addGlobalMonitorForEvents(.mouseMoved)` returns non-nil)
2. The app IS detecting windows under the cursor and attempting hover raise
3. ALL AX API calls fail with error -25211 (API disabled — Accessibility not granted)
4. `AXRaiseAction` fails with -25205 (action unsupported)
5. The FFM mode is `raiseOnHover`, which triggers constant AX failures as the mouse moves

---

## Phase 1: Initial Investigation (PID 44383, print() only)

### Finding: Zero `[AutoPaste]` Messages in Console

The original app used `print()` for logging. Swift `print()` writes to stdout only, which:
- IS visible in Xcode's debug console
- IS NOT captured by macOS unified logging (`log show` / Console.app)

This made the initial diagnosis impossible via Console logs alone.

### Finding: TCC Denials in tccd Logs

From `log show --predicate 'subsystem == "com.apple.TCC" AND process == "tccd"'`:

**kTCCServiceListenEvent — DENIED:**
```
20:55:09.352 AUTHREQ_RESULT: msgID=44383.1, authValue=0, authReason=5
```

**kTCCServiceAccessibility — DENIED (3 times):**
```
20:55:09.356 Failed to match existing code requirement for subject com.localSTT.mac and service kTCCServiceAccessibility
20:55:09.356 AUTHREQ_RESULT: msgID=385.19663, authValue=0, authReason=5

20:55:11.650 Failed to match existing code requirement for subject com.localSTT.mac and service kTCCServiceAccessibility
20:55:11.650 AUTHREQ_RESULT: msgID=44383.3, authValue=0, authReason=5

20:55:11.661 Failed to match existing code requirement for subject com.localSTT.mac and service kTCCServiceAccessibility
20:55:11.661 AUTHREQ_RESULT: msgID=44383.4, authValue=0, authReason=5
```

**authReason=5** means "code requirement mismatch" — the stored csreq doesn't match the current binary.

### TCC Database vs Runtime

**System TCC DB** (`/Library/Application Support/com.apple.TCC/TCC.db`):
```
kTCCServiceAccessibility | com.localSTT.mac | auth_value=2 (allowed) | auth_reason=4 (user set)
```

**User TCC DB** (`~/Library/Application Support/com.apple.TCC/TCC.db`):
```
kTCCServiceMicrophone | com.localSTT.mac | auth_value=2 (allowed)
```

**kTCCServiceListenEvent** — NO ENTRY in either database. Never granted.

The paradox: Accessibility appears "allowed" in the DB but is DENIED at runtime because ad-hoc signing changes the code hash on every rebuild, invalidating the stored csreq.

---

## Phase 2: Definitive Evidence (PID 52626, os.Logger)

After switching `print()` to `os.Logger` and rebuilding, relaunched the app and captured definitive unified log output.

### Answer 1: Mouse Tracking DID Start Successfully

```
21:07:29.229 I [com.localSTT.mac:AutoPaste] Mouse tracking started
```

**Surprising finding:** Despite kTCCServiceListenEvent being denied (authValue=0), `NSEvent.addGlobalMonitorForEvents(.mouseMoved)` returned a non-nil monitor and IS receiving events. This contradicts my initial hypothesis. macOS appears to allow `.mouseMoved` monitoring without Input Monitoring permission (Input Monitoring is required for keystrokes, not mouse position).

### Answer 2: Window Detection IS Working (Hover Raise Triggered)

The app detected windows under the cursor and attempted hover raise. Evidence: AX calls were made targeting specific PIDs (50726, 648, 25642), which means `handleMouseMoved()` -> `windowInfoUnderMouse()` -> `handleHoverRaise()` all worked. The `Tracking:` info messages are present but filtered as `logger.info()` (not persisted by default).

### Answer 3: ALL AXUIElement Calls Fail with -25211

**Error -25211 = `kAXErrorAPIDisabled`** — the Accessibility API is disabled for this app.

```
21:07:30.103 E [com.localSTT.mac:AutoPaste] raiseWindow: AXUIElementCopyAttributeValue failed (-25211), falling back to activate
21:07:30.103 E [com.localSTT.mac:AutoPaste] activateApp: AXFrontmost failed (-25211) for PID 50726
```

This error repeats for EVERY hover raise attempt (10+ times in 3 seconds), targeting multiple PIDs. The call sequence:
1. `AXUIElementCopyAttributeValue(app, kAXWindowsAttribute)` -> error -25211
2. Falls back to `activateApp()`
3. `AXUIElementSetAttributeValue(app, kAXFrontmostAttribute, true)` -> error -25211
4. Falls back to `NSRunningApplication.activate()` (which may silently fail from background)

### Answer 4: AXRaiseAction Also Fails with -25205

```
21:07:58.340 E [com.localSTT.mac:AutoPaste] raiseWindow: AXRaiseAction failed (-25205)
```

**Error -25205 = `kAXErrorCannotComplete`** — The action could not be completed (likely because Accessibility is not granted).

### Answer 5: Errors Occur Alongside TCC Denials

The TCC accessibility requests from within the app's process also show denials:
```
21:07:30.079 SEND: service=kTCCServiceAccessibility
21:07:30.086 RECV: auth_value=0, result=false, auth_reason=5
```

Followed immediately by the XPC assertion failure:
```
21:07:30.104 E assertion failed: 24G517: libxpc.dylib + 101752: 0x7d
```

### Answer 6: No Paste Attempted

No `pasteText:` messages appeared because no transcription was performed during the test. The paste flow was not tested, but it would also fail because:
- `activateApp()` would fail (AX error -25211)
- `sendPasteKeystroke()` via CGEvent might also be blocked without Accessibility

---

## Complete Timeline (PID 52626)

```
21:07:00.046  App process starts, Keychain access
21:07:29.011  CoreAnalytics daemon connected
21:07:29.015  "No windows open yet"
21:07:29.016  TCC request: kTCCServiceListenEvent -> DENIED (authValue=0, authReason=5)
21:07:29.019  SkyLight connection (window server)
21:07:29.116  Window state restoration begins (main-AppWindow-1)
21:07:29.152  Window 7da2 created (main window)
21:07:29.206  Window ordered front
21:07:29.229  [AutoPaste] Mouse tracking started  <-- setupServices() called, monitor succeeded
21:07:30.078  TCC request: kTCCServiceAccessibility -> DENIED (authValue=0, authReason=5)
21:07:30.095  TCC request: kTCCServiceAccessibility -> DENIED again
21:07:30.103  [AutoPaste] AXUIElementCopyAttributeValue failed (-25211)  <-- First AX error
21:07:30.103  [AutoPaste] activateApp: AXFrontmost failed (-25211)
21:07:30.104  XPC assertion failure (0x7d)
21:07:30-32   10+ more AX failures as user moves mouse (hover raise mode)
21:07:57.952  More AX failures on different PIDs
21:07:58.340  AXRaiseAction failed (-25205)
21:08:06.932  App closed
```

---

## Root Causes (Confirmed)

### 1. TCC Code Signature Mismatch (PRIMARY)

The app uses ad-hoc code signing (`CODE_SIGN_IDENTITY: "-"`, `flags=0x2(adhoc)`). Every rebuild generates a new code hash. The TCC database has an allowed entry with the OLD hash's csreq. At runtime, `tccd` compares the current binary's hash against the stored csreq, finds a mismatch, and **denies access** — returning `authReason=5`.

**Codesign details:**
```
Identifier=com.localSTT.mac
CodeDirectory flags=0x2(adhoc)
Signature=adhoc
TeamIdentifier=not set
Internal requirements count=0 size=12
```

**Result:** ALL AXUIElement API calls return error -25211 (`kAXErrorAPIDisabled`).

### 2. FFM Mode is raiseOnHover (Amplifies the Problem)

The app's FFM mode is set to `raiseOnHover` (confirmed from UserDefaults: `ffm_mode` is set). This means EVERY mouse movement triggers an AX call attempt, which generates a flood of -25211 errors. In `trackOnly` mode, AX calls would only happen at paste time, reducing the error spam.

### 3. NSRunningApplication.activate() May Not Work from LSUIElement

When AX fails, the code falls back to `NSRunningApplication.activate()`. But this API may not effectively bring windows to the front when called from an LSUIElement (background-only) app. No error is logged for this fallback, but it likely fails silently.

### 4. print() Logging Was Invisible (FIXED)

The original `print()` calls went to stdout only. **This has been fixed** — the code now uses `os.Logger` with subsystem `com.localSTT.mac` and category `AutoPaste`/`AppState`. Error-level messages are now persisted in the unified log. Info-level messages require `--info` flag with `log show`.

---

## Additional Errors Found

### CoreAudio -10877 (kAudioCodecBadPropertySizeError)
```
20:55:24.836 E (CoreAudio) throwing -10877
```
Occurs during audio engine start/stop cycles. May indicate AVAudioEngine format mismatch.

### CFPasteboard -22 (EINVAL)
```
20:55:37.029 Error occurred requesting metadata to refresh cache for pasteboard general result: -22
```
Clipboard metadata refresh error. Non-critical but worth noting.

### Network Timeout (IPv6)
```
20:59:08.556 E nw_read_request_report [C1] Receive failed with error "Operation timed out"
20:59:08.557 IPv6#032dbd39.443 failed channel-flow
```
Network connection (likely Groq API) timed out over IPv6.

---

## Recommended Fixes

### Fix 1: Reset TCC Accessibility After Rebuild (Immediate)

After every rebuild, the user must:
1. Open System Settings > Privacy & Security > Accessibility
2. Remove `LocalSTTMac` (if present)
3. Re-add the rebuilt `.app` bundle
4. Restart the app

### Fix 2: Use Self-Signed Certificate Instead of Ad-Hoc (Long-term)

Create a self-signed code signing certificate in Keychain Access and use it in project.yml. This produces a stable code signing identity that persists across rebuilds, preventing TCC csreq mismatches.

### Fix 3: Add AXIsProcessTrusted() Check in UI

Before attempting any AX calls, check `AXIsProcessTrusted()` and show a prompt/button in the UI to guide the user to grant Accessibility. This provides immediate user feedback instead of silent failures.

### Fix 4: Reduce Error Spam in raiseOnHover Mode

When AX fails with -25211, disable further AX attempts until `AXIsProcessTrusted()` returns true. Currently the app floods the log with identical errors every 150ms as the mouse moves.

### Fix 5: Handle kTCCServiceListenEvent (Not Blocking, But Good Practice)

Although `NSEvent.addGlobalMonitorForEvents(.mouseMoved)` works without Input Monitoring, consider checking `AXIsProcessTrusted()` as a proxy for global event monitoring capability.

---

## Files Referenced

| File | Lines | Purpose |
|------|-------|---------|
| `macos/Sources/LocalSTTMac/Services/AutoPasteManager.swift` | 78-90 | `startTracking()` — creates global mouse monitor |
| `macos/Sources/LocalSTTMac/Services/AutoPasteManager.swift` | 102-130 | `handleMouseMoved()` — tracking + hover raise |
| `macos/Sources/LocalSTTMac/Services/AutoPasteManager.swift` | 161-184 | `handleHoverRaise()` — triggers AX calls |
| `macos/Sources/LocalSTTMac/Services/AutoPasteManager.swift` | 190-247 | `raiseWindow()` — AXUIElement window raise (fails with -25211) |
| `macos/Sources/LocalSTTMac/Services/AutoPasteManager.swift` | 263-275 | `activateApp()` — AXFrontmost + NSRunningApplication (both fail) |
| `macos/Sources/LocalSTTMac/Services/AutoPasteManager.swift` | 287-336 | `pasteText()` — paste flow (not tested, would also fail) |
| `macos/Sources/LocalSTTMac/Services/AutoPasteManager.swift` | 341-363 | `sendPasteKeystroke()` — CGEvent Cmd+V |
| `macos/Sources/LocalSTTMac/MacAppState.swift` | 137-155 | `setupServices()` — creates AutoPasteManager |
| `macos/Sources/LocalSTTMac/MacAppState.swift` | 268-281 | Post-transcription auto-paste trigger |
| `macos/Sources/LocalSTTMac/Views/MainWindowView.swift` | 55-57 | `.onAppear { setupServices() }` — where services are initialized |

## AX Error Code Reference

| Code | Name | Meaning |
|------|------|---------|
| -25211 | kAXErrorAPIDisabled | The Accessibility API is disabled for this application |
| -25205 | kAXErrorCannotComplete | The action could not be completed |
| -25204 | kAXErrorNotImplemented | The function/attribute is not implemented |

## TCC Auth Reason Reference

| Reason | Meaning |
|--------|---------|
| 0 | Unknown/not set |
| 4 | User set (approved in System Settings) |
| 5 | Code requirement mismatch (signature doesn't match stored csreq) |
