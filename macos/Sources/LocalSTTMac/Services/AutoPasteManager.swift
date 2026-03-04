import AppKit
import ApplicationServices
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.localSTT.mac", category: "AutoPaste")

/// Focus-follows-mouse modes.
enum FFMMode {
    case trackOnly     // Track mouse position, activate target only at paste time
    case raiseOnHover  // Raise windows as mouse hovers over them
}

/// Manages mouse tracking, window detection, and auto-paste to target windows.
///
/// Uses all-native macOS APIs:
/// - NSEvent global + local monitors for mouse tracking (event-driven, not polling)
/// - NSWindow.windowNumber(at:) + CGWindowListCopyWindowInfo for window detection
/// - NSRunningApplication.activate for app activation
/// - AXUIElement for window raise (hover mode)
/// - CGEvent for paste keystroke (Cmd+V)
/// - NSPasteboard for clipboard management
final class AutoPasteManager {
    var isEnabled: Bool = true {
        didSet {
            if isEnabled {
                startTracking()
            } else {
                stopTracking()
            }
        }
    }

    var mode: FFMMode = .trackOnly

    /// Currently tracked window info (PID of app under mouse cursor).
    private(set) var trackedPID: pid_t = 0
    private(set) var trackedAppName: String = ""
    /// CGWindowID of the tracked window (for precise raise targeting).
    private(set) var trackedWindowID: CGWindowID = 0

    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var deferredRaiseWork: DispatchWorkItem?
    private var lastHoverPID: pid_t = 0
    private var lastHoverTime: Date = .distantPast
    private var lastRaiseTime: Date = .distantPast
    private var lastWindowCheckTime: Date = .distantPast

    /// Apps to exclude from FFM tracking and raise entirely.
    /// Finder is excluded from this list (handled by kCGWindowLayer desktop filter instead).
    /// LocalSTT itself is handled separately via `ownPID` — tracked for transitions but never raised.
    private static let excludedApps: Set<String> = [
        // Core system UI
        "Dock", "Window Server", "Wallpaper",
        // Menu bar / status UI
        "Control Center", "Notification Center", "SystemUIServer",
        "TextInputMenuAgent", "TextInputSwitcher",
        "PasswordsMenuBarExtra",
        // Window management
        "WindowManager",
        // Auth / security dialogs
        "SecurityAgent", "coreautha",
        // Session / screen
        "loginwindow", "screencaptureui", "ScreenSaverEngine",
        // Misc system agents that own windows
        "SiriNCService", "AccessibilityVisualsAgent",
        "Open and Save Panel Service", "CursorUIViewService",
        "nsattributedstringagent", "LinkedNotesUIService",
        "ThemeWidgetControlViewService", "Universal Control",
    ]

    /// Our own PID — tracked for hover transitions but never raised (prevents focus trap).
    private static let ownPID: pid_t = ProcessInfo.processInfo.processIdentifier

    /// Minimum dwell time before raising in hover mode.
    private static let hoverDwellTime: TimeInterval = 0.05

    /// Cooldown between raise actions.
    private static let hoverCooldown: TimeInterval = 0.15

    /// Minimum interval between window server queries (throttle mouse events).
    private static let windowCheckInterval: TimeInterval = 0.05

    init() {
        startTracking()
    }

    deinit {
        stopTracking()
    }

    // MARK: - Mouse Tracking

    /// Recreate the mouse monitor (call after Accessibility permission is granted).
    func restartTracking() {
        stopTracking()
        if isEnabled {
            startTracking()
        }
    }

    private func startTracking() {
        guard mouseMonitor == nil else { return }

        // Global monitor: captures mouse events when OTHER apps are active
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleMouseMoved(event)
        }

        // Local monitor: captures mouse events when OUR app is active.
        // The global monitor goes silent when we're frontmost, so without this,
        // FFM tracking stops entirely when LocalSTT's window is in the foreground.
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleMouseMoved(event)
            return event  // Pass through — don't consume mouse movement
        }

        if mouseMonitor == nil {
            logger.error("Failed to create global mouse monitor — check Accessibility permissions")
        } else {
            logger.info("Mouse tracking started")
        }
    }

    private func stopTracking() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseMonitor = nil
        }
        deferredRaiseWork?.cancel()
        deferredRaiseWork = nil
        trackedPID = 0
        trackedAppName = ""
        trackedWindowID = 0
    }

    private func handleMouseMoved(_ event: NSEvent) {
        // Throttle window server queries to avoid excessive CPU usage
        let now = Date()
        guard now.timeIntervalSince(lastWindowCheckTime) >= Self.windowCheckInterval else { return }
        lastWindowCheckTime = now

        let point = NSEvent.mouseLocation

        // Get window under cursor
        guard let info = windowInfoUnderMouse(at: point) else { return }

        // Skip excluded system apps entirely
        guard !Self.excludedApps.contains(info.appName) else { return }

        let isSelf = info.pid == Self.ownPID

        // Update paste target only for other apps (not our own window)
        if !isSelf {
            if info.pid != trackedPID {
                logger.debug("Tracking: \(info.appName, privacy: .public) (PID \(info.pid), window \(info.windowID))")
            }
            trackedPID = info.pid
            trackedAppName = info.appName
            trackedWindowID = info.windowID
        }

        // Raise on hover mode
        if mode == .raiseOnHover {
            if isSelf {
                // Track PID transition but don't raise self (prevents focus trap).
                // This lets the deferred timer for the NEXT app start from a clean state.
                if lastHoverPID != Self.ownPID {
                    lastHoverPID = Self.ownPID
                    lastHoverTime = now
                    deferredRaiseWork?.cancel()
                    deferredRaiseWork = nil
                }
            } else {
                handleHoverRaise(pid: info.pid, windowID: info.windowID)
            }
        }
    }

    // MARK: - Window Detection

    /// Window info result from detection.
    private struct WindowInfo {
        let pid: pid_t
        let appName: String
        let windowID: CGWindowID
    }

    /// Get the PID, app name, and window ID under the given screen point.
    private func windowInfoUnderMouse(at point: NSPoint) -> WindowInfo? {
        let windowNumber = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        guard windowNumber > 0 else { return nil }

        let windowID = CGWindowID(windowNumber)
        guard let windowInfoList = CGWindowListCopyWindowInfo(
            .optionIncludingWindow, windowID
        ) as? [[String: Any]] else { return nil }

        guard let windowInfo = windowInfoList.first,
              let pid = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
              let name = windowInfo[kCGWindowOwnerName as String] as? String
        else { return nil }

        // Skip non-standard layer windows (desktop = kCGDesktopWindowLevel, overlays, etc.)
        // Normal windows are layer 0; anything else is a system surface we shouldn't interact with.
        if let layer = windowInfo[kCGWindowLayer as String] as? Int, layer != 0 {
            return nil
        }

        return WindowInfo(pid: pid, appName: name, windowID: windowID)
    }

    // MARK: - Hover Raise

    private func handleHoverRaise(pid: pid_t, windowID: CGWindowID) {
        let now = Date()

        if pid != lastHoverPID {
            // New window — reset dwell timer and schedule deferred raise.
            // The deferred timer ensures the raise fires even if the mouse stops moving,
            // which the old approach (checking dwell on next mouse event) couldn't handle.
            lastHoverPID = pid
            lastHoverTime = now
            scheduleDeferredRaise(pid: pid, windowID: windowID)
            return
        }

        // Same window, mouse still moving — check if we can raise immediately
        guard now.timeIntervalSince(lastHoverTime) >= Self.hoverDwellTime else { return }
        guard now.timeIntervalSince(lastRaiseTime) >= Self.hoverCooldown else { return }
        guard !NSEvent.modifierFlags.contains(.command) else { return }

        // Cancel deferred raise since we're raising now
        deferredRaiseWork?.cancel()
        deferredRaiseWork = nil

        logger.debug("Hover raise: PID \(pid), window \(windowID)")
        raiseWindow(pid: pid, windowID: windowID)
        lastRaiseTime = now
    }

    /// Schedule a raise after dwell time, even if the mouse stops moving.
    ///
    /// Without this, a raise only triggers when a subsequent mouse event checks the dwell timer.
    /// If the mouse enters a window and stops, no further events arrive and the raise never fires.
    /// The timer also respects the cooldown period from the last raise.
    private func scheduleDeferredRaise(pid: pid_t, windowID: CGWindowID) {
        deferredRaiseWork?.cancel()

        let timeSinceLastRaise = Date().timeIntervalSince(lastRaiseTime)
        let cooldownRemaining = max(0, Self.hoverCooldown - timeSinceLastRaise)
        let delay = max(Self.hoverDwellTime, cooldownRemaining)

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard self.lastHoverPID == pid else { return }
            guard !NSEvent.modifierFlags.contains(.command) else { return }

            logger.debug("Deferred raise: PID \(pid), window \(windowID)")
            self.raiseWindow(pid: pid, windowID: windowID)
            self.lastRaiseTime = Date()
        }

        deferredRaiseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Raise the window matching the given CGWindowID via AXUIElement.
    ///
    /// Matches AXUIElement windows to our CGWindowID by comparing position/size bounds
    /// (public API approach — _AXUIElementGetWindow is private).
    private func raiseWindow(pid: pid_t, windowID: CGWindowID) {
        // Get the bounds of our target window from CGWindowList
        guard let targetBounds = windowBounds(for: windowID) else {
            logger.warning("raiseWindow: no bounds for window \(windowID), falling back to activate")
            activateApp(pid: pid)
            return
        }

        let app = AXUIElementCreateApplication(pid)

        // Get all AX windows for the app
        var windowsRef: CFTypeRef?
        let axResult = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
        guard axResult == .success,
              let windows = windowsRef as? [AXUIElement]
        else {
            logger.warning("raiseWindow: AXUIElementCopyAttributeValue failed (\(axResult.rawValue)), falling back to activate")
            activateApp(pid: pid)
            return
        }

        // Match AXUIElement by position+size against CGWindowList bounds
        var targetWindow: AXUIElement?
        for window in windows {
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
                  AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success
            else { continue }

            var pos = CGPoint.zero
            var size = CGSize.zero
            AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)

            // Match with small tolerance (coordinate rounding)
            if abs(pos.x - targetBounds.origin.x) < 2 &&
               abs(pos.y - targetBounds.origin.y) < 2 &&
               abs(size.width - targetBounds.size.width) < 2 &&
               abs(size.height - targetBounds.size.height) < 2 {
                targetWindow = window
                break
            }
        }

        // Fall back to first window if no match (single-window apps)
        let windowToRaise = targetWindow ?? windows.first
        if let window = windowToRaise {
            let raiseResult = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            if raiseResult != .success {
                logger.warning("raiseWindow: AXRaiseAction failed (\(raiseResult.rawValue))")
            }
        } else {
            logger.warning("raiseWindow: no AX windows found for PID \(pid)")
        }

        activateApp(pid: pid)
    }

    /// Get CGRect bounds for a specific CGWindowID.
    private func windowBounds(for windowID: CGWindowID) -> CGRect? {
        guard let infoList = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let info = infoList.first,
              let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else { return nil }
        return bounds
    }

    /// Activate an app by PID.
    ///
    /// Uses both AXUIElement (force frontmost) and NSRunningApplication as backup.
    /// AXUIElement is more reliable from LSUIElement background apps.
    private func activateApp(pid: pid_t) {
        // AX approach: force the app to be frontmost (works from background apps)
        let app = AXUIElementCreateApplication(pid)
        let axResult = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if axResult != .success {
            logger.warning("activateApp: AXFrontmost failed (\(axResult.rawValue)) for PID \(pid)")
        }

        // NSRunningApplication approach as backup
        if let runningApp = NSRunningApplication(processIdentifier: pid) {
            runningApp.activate()
        }
    }

    // MARK: - Paste Flow

    /// Paste text to the window currently tracked under the mouse cursor.
    ///
    /// Flow:
    /// 1. Activate target app (in track_only mode)
    /// 2. Save current clipboard
    /// 3. Set text to clipboard
    /// 4. Send Cmd+V via CGEvent
    /// 5. Restore original clipboard after delay
    func pasteText(_ text: String, clipboardDelay: Double = 0.05, pasteDelay: Double = 0.05) {
        let targetPID = trackedPID
        let targetApp = trackedAppName

        logger.info("pasteText: target=\(targetApp, privacy: .public) (PID \(targetPID)), text=\(text.prefix(40), privacy: .public)...")

        // If no tracked window, just copy to clipboard
        guard targetPID > 0 else {
            logger.info("pasteText: no tracked window, copying to clipboard only")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return
        }

        // Save original clipboard contents (all types per item for rich content)
        let savedItems: [[(NSPasteboard.PasteboardType, Data)]] = NSPasteboard.general.pasteboardItems?.compactMap { item -> [(NSPasteboard.PasteboardType, Data)]? in
            let pairs = item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            }
            return pairs.isEmpty ? nil : pairs
        } ?? []

        // Set transcribed text to clipboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        // Activate the target app (use aggressive AX + NSRunningApplication approach)
        logger.info("pasteText: activating \(targetApp, privacy: .public)")
        activateApp(pid: targetPID)

        // Wait for target app to become active before sending paste keystroke.
        // 100ms activation delay gives the target app time to gain focus.
        let activationDelay = 0.1
        DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay) {
            // Additional clipboard sync delay, then paste
            DispatchQueue.main.asyncAfter(deadline: .now() + clipboardDelay) {
                // Re-assert focus right before paste in case focus shifted during delay
                self.activateApp(pid: targetPID)
                logger.info("pasteText: sending Cmd+V to \(targetApp, privacy: .public)")
                self.sendPasteKeystroke()

                // Restore clipboard after paste delay
                DispatchQueue.main.asyncAfter(deadline: .now() + pasteDelay) {
                    self.restoreClipboard(savedItems)
                    logger.debug("pasteText: clipboard restored")
                }
            }
        }
    }

    // MARK: - CGEvent Paste

    /// Send Cmd+V keystroke via CGEvent.
    private func sendPasteKeystroke() {
        let source = CGEventSource(stateID: .hidSystemState)

        // V key = virtual key 0x09
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        else {
            logger.error("sendPasteKeystroke: FAILED to create CGEvent")
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        // CRITICAL for macOS 15 Sequoia: set timestamp or events are silently dropped.
        // keyDown and keyUp MUST have distinct increasing timestamps or keyUp may be dropped.
        let t = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        keyDown.timestamp = t
        keyUp.timestamp = t + 1_000  // +1µs ensures keyUp is strictly later than keyDown

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        logger.info("sendPasteKeystroke: Cmd+V posted")
    }

    // MARK: - Clipboard Restore

    private func restoreClipboard(_ savedItems: [[(NSPasteboard.PasteboardType, Data)]]) {
        // Always clear — even if original was empty, remove the transcribed text
        NSPasteboard.general.clearContents()
        guard !savedItems.isEmpty else { return }

        // Restore each original item with all its types
        let pasteboardItems = savedItems.map { typeDataPairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in typeDataPairs {
                item.setData(data, forType: type)
            }
            return item
        }
        NSPasteboard.general.writeObjects(pasteboardItems)
    }
}
