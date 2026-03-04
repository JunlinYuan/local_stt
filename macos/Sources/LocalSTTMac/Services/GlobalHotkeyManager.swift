import AppKit
import Foundation

/// Manages global hotkey detection: hold Left Control to record.
///
/// Uses NSEvent global/local monitors for `.flagsChanged` and `.keyDown` events.
/// Discriminates Left vs Right Control via keyCode 59.
/// Cancels recording if any non-modifier key is pressed while Control is held
/// (e.g., Ctrl+C, Ctrl+V are keyboard shortcuts, not recording attempts).
/// Requires Accessibility permission for global monitoring.
final class GlobalHotkeyManager {
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyDownMonitor: Any?
    private var localKeyDownMonitor: Any?
    private var isControlPressed = false

    private let onPress: () -> Void
    private let onRelease: () -> Void
    private let onCancel: () -> Void

    init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void, onCancel: @escaping () -> Void = {}) {
        self.onPress = onPress
        self.onRelease = onRelease
        self.onCancel = onCancel
        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Accessibility Check

    /// Check Accessibility permission status without showing a prompt.
    static func checkAccessibility() -> Bool {
        return AXIsProcessTrusted()
    }

    /// Check Accessibility permission and show system prompt if not granted.
    static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Monitoring

    /// Recreate all monitors (call after Accessibility permission is granted).
    func restartMonitoring() {
        stopMonitoring()
        startMonitoring()
    }

    private func startMonitoring() {
        // Global monitors — work when any app is focused (requires Accessibility)
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
        }

        // Local monitors — work when our app is focused (no permission needed)
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
            return event
        }
    }

    private func stopMonitoring() {
        for monitor in [globalFlagsMonitor, localFlagsMonitor, globalKeyDownMonitor, localKeyDownMonitor] {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        globalFlagsMonitor = nil
        localFlagsMonitor = nil
        globalKeyDownMonitor = nil
        localKeyDownMonitor = nil
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        // Only respond to Left Control (keyCode 59)
        // Right Control is keyCode 62 — ignore it
        guard event.keyCode == 59 else { return }

        let controlDown = event.modifierFlags.contains(.control)

        if controlDown && !isControlPressed {
            // Control just pressed
            isControlPressed = true
            onPress()
        } else if !controlDown && isControlPressed {
            // Control just released
            isControlPressed = false
            onRelease()
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        // Any non-modifier key pressed while Control is held = cancel recording.
        // This means Ctrl+C, Ctrl+V, etc. are treated as keyboard shortcuts, not recording.
        guard isControlPressed else { return }
        isControlPressed = false
        onCancel()
    }
}
