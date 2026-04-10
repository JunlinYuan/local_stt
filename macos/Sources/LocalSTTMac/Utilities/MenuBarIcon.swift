import AppKit

/// Generates custom menu bar template images programmatically.
///
/// The icon is a speech bubble with a waveform inside — distinctive from the
/// generic `mic` SF Symbol that looks like the macOS recording indicator.
/// Template images are monochrome; macOS handles light/dark rendering.
enum MenuBarIcon {

    /// Idle state: speech bubble outline with waveform.
    static func idle() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            // Speech bubble path (rounded rect with tail)
            let bubbleRect = NSRect(x: 1, y: 5, width: 16, height: 11)
            let bubble = NSBezierPath(roundedRect: bubbleRect, xRadius: 3, yRadius: 3)
            bubble.lineWidth = 1.4
            bubble.stroke()

            // Tail (small triangle at bottom-left)
            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: 5, y: 5))
            tail.line(to: NSPoint(x: 3, y: 1.5))
            tail.line(to: NSPoint(x: 8, y: 5))
            tail.lineWidth = 1.4
            tail.stroke()

            // Waveform bars inside bubble (5 bars, centered)
            let barWidth: CGFloat = 1.4
            let barSpacing: CGFloat = 2.4
            let barHeights: [CGFloat] = [3, 5.5, 7, 5.5, 3]
            let totalWidth = CGFloat(barHeights.count) * barWidth + CGFloat(barHeights.count - 1) * (barSpacing - barWidth)
            let startX = rect.midX - totalWidth / 2

            for (i, height) in barHeights.enumerated() {
                let x = startX + CGFloat(i) * barSpacing
                let y = 10.5 - height / 2
                let barRect = NSRect(x: x, y: y, width: barWidth, height: height)
                let bar = NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2)
                bar.fill()
            }

            return true
        }
        image.isTemplate = true
        return image
    }

    /// Recording state: filled speech bubble with waveform (inverted).
    static func recording() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            // Filled speech bubble
            let bubbleRect = NSRect(x: 1, y: 5, width: 16, height: 11)
            let bubble = NSBezierPath(roundedRect: bubbleRect, xRadius: 3, yRadius: 3)
            bubble.fill()

            // Filled tail
            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: 5, y: 5))
            tail.line(to: NSPoint(x: 3, y: 1.5))
            tail.line(to: NSPoint(x: 8, y: 5))
            tail.fill()

            // Waveform bars (white/clear on filled bubble)
            NSColor.white.setFill()
            let barWidth: CGFloat = 1.4
            let barSpacing: CGFloat = 2.4
            let barHeights: [CGFloat] = [3, 5.5, 7, 5.5, 3]
            let totalWidth = CGFloat(barHeights.count) * barWidth + CGFloat(barHeights.count - 1) * (barSpacing - barWidth)
            let startX = rect.midX - totalWidth / 2

            for (i, height) in barHeights.enumerated() {
                let x = startX + CGFloat(i) * barSpacing
                let y = 10.5 - height / 2
                let barRect = NSRect(x: x, y: y, width: barWidth, height: height)
                let bar = NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2)
                bar.fill()
            }

            return true
        }
        image.isTemplate = true
        return image
    }
}
