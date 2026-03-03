import SwiftUI

extension Color {
    /// Create a Color from a hex string (e.g., "#0a0a0b" or "0a0a0b").
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&rgb)

        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

// MARK: - App Colors

extension Color {
    /// App background — near-black.
    static let appBackground = Color(hex: "#0a0a0b")

    /// Surface for cards and panels.
    static let appSurface = Color(hex: "#18181b")

    /// Subtle border color.
    static let appBorder = Color(hex: "#27272a")

    /// Recording state — red.
    static let recordingRed = Color(hex: "#ef4444")

    /// Processing/transcribing state — amber.
    static let processingAmber = Color(hex: "#f59e0b")

    /// Accent teal — ready state, links, buttons.
    static let accentTeal = Color(hex: "#2dd4bf")

    /// Muted text.
    static let textMuted = Color(hex: "#a1a1aa")

    /// Primary text.
    static let textPrimary = Color(hex: "#fafafa")
}
