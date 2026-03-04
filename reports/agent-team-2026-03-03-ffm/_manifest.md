# FFM Debug Mission

**Goal**: Fix auto-raise and auto-paste in LocalSTT macOS app — both features not working.

## Root Cause

**Missing Accessibility permission.** The app was never granted Accessibility access in System Settings > Privacy & Security > Accessibility. Without it, all AXUIElement APIs fail (error -25211 / -25204), which breaks:
- Window raise (AXUIElementPerformAction kAXRaiseAction)
- App activation (AXUIElementSetAttributeValue kAXFrontmostAttribute)
- CGEvent posting for paste (Cmd+V)

## Fixes Implemented

| # | Fix | File |
|---|-----|------|
| 1 | `print()` → `os.Logger` for visible diagnostics | AutoPasteManager.swift, MacAppState.swift |
| 2 | Excluded app name: dynamic `CFBundleName` instead of hardcoded `"LocalSTT"` | AutoPasteManager.swift |
| 3 | Expanded excluded apps list (SecurityAgent, Window Server, etc.) | AutoPasteManager.swift |
| 4 | CGEvent timestamp: `t + 1_000` (1µs offset) for distinct keyDown/keyUp | AutoPasteManager.swift |
| 5 | AXUIElement activation + NSRunningApplication fallback | AutoPasteManager.swift |
| 6 | 100ms activation delay before paste keystroke | AutoPasteManager.swift |
| 7 | Re-assert focus before sending Cmd+V | AutoPasteManager.swift |
| 8 | Multi-type clipboard save/restore | AutoPasteManager.swift |
| 9 | Always clear clipboard on restore (even when original empty) | AutoPasteManager.swift |
| 10 | `AXIsProcessTrustedWithOptions` check + prompt on launch | MacAppState.swift |
| 11 | `restartMonitors()` refreshes permission state | MacAppState.swift |

## Status: Complete

All code fixes implemented. User needs to grant Accessibility permission in System Settings for full functionality.

## Reports
- `code-analyst.md` — Full pipeline trace, 5 bugs identified
- `api-researcher.md` — macOS API research (pending)
- `console-investigator.md` — Log investigation
