import SwiftUI

/// Hold-to-record button for the Mac window.
///
/// Uses NSViewRepresentable + NSPressGestureRecognizer for reliable press/release
/// detection (same pattern as iOS UILongPressGestureRecognizer bridge).
/// The global hotkey (Left Control) handles most recording — this button is
/// for in-window use and visual feedback.
struct MacRecordButton: View {
    @Environment(MacAppState.self) private var appState
    @State private var isPressed = false
    @State private var pulseAnimation = false
    @State private var timer: Timer?

    private let buttonHeight: CGFloat = 80
    private let cornerRadius: CGFloat = 16

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(fillColor)

            borderView

            contentView
        }
        .frame(maxWidth: .infinity)
        .frame(height: buttonHeight)
        .overlay {
            MacHoldGestureView(
                onBegan: { startRecording() },
                onEnded: { stopRecording() }
            )
        }
        .onChange(of: appState.state) { _, newState in
            if case .recording = newState {
                startDurationTimer()
            } else {
                stopDurationTimer()
            }
        }
        .onDisappear {
            stopDurationTimer()
        }
    }

    // MARK: - Visual States

    @ViewBuilder
    private var borderView: some View {
        switch appState.state {
        case .recording:
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.recordingRed, lineWidth: 3)
                .scaleEffect(pulseAnimation ? 1.02 : 1.0)
                .opacity(pulseAnimation ? 0.7 : 1.0)
                .animation(
                    .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                    value: pulseAnimation
                )
                .onAppear { pulseAnimation = true }
                .onDisappear { pulseAnimation = false }

        case .transcribing:
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.processingAmber, lineWidth: 3)

        default:
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.accentTeal, lineWidth: 2)
        }
    }

    private var fillColor: Color {
        switch appState.state {
        case .recording: return Color.recordingRed.opacity(0.1)
        case .transcribing: return Color.processingAmber.opacity(0.08)
        default: return Color.accentTeal.opacity(0.08)
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch appState.state {
        case .recording:
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.recordingRed)
                    .frame(width: 18, height: 18)
                Text(formatDuration(appState.recordingDuration))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Color.recordingRed)
            }

        case .transcribing:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Transcribing...")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.processingAmber)
            }

        default:
            VStack(spacing: 4) {
                Image(systemName: "mic.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentTeal)
                Text("Hold to record  \u{2022}  \u{2303} Left Control")
                    .font(.caption)
                    .foregroundStyle(Color.textMuted)
            }
        }
    }

    // MARK: - Actions

    private func startRecording() {
        isPressed = true
        appState.startRecording()
    }

    private func stopRecording() {
        isPressed = false
        appState.stopRecordingAndTranscribe()
    }

    // MARK: - Duration Timer

    private func startDurationTimer() {
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            guard case .recording = appState.state else { return }
            appState.recordingDuration += 1.0
        }
        // Add to .common mode so timer fires during mouse tracking/scrolling
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopDurationTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Hold Gesture (AppKit Bridge)

/// Wraps `NSPressGestureRecognizer` for reliable mouse-down/up detection on macOS.
struct MacHoldGestureView: NSViewRepresentable {
    let onBegan: () -> Void
    let onEnded: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let gesture = NSPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleGesture(_:))
        )
        gesture.minimumPressDuration = 0
        view.addGestureRecognizer(gesture)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onBegan: onBegan, onEnded: onEnded)
    }

    class Coordinator: NSObject {
        let onBegan: () -> Void
        let onEnded: () -> Void

        init(onBegan: @escaping () -> Void, onEnded: @escaping () -> Void) {
            self.onBegan = onBegan
            self.onEnded = onEnded
        }

        @objc func handleGesture(_ gesture: NSPressGestureRecognizer) {
            switch gesture.state {
            case .began:
                onBegan()
            case .ended, .cancelled, .failed:
                onEnded()
            default:
                break
            }
        }
    }
}
