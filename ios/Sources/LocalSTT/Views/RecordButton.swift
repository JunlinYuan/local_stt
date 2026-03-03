import SwiftUI

/// Hold-to-record button — full-width rounded rectangle, WeChat-style.
///
/// Uses `UILongPressGestureRecognizer` via `UIViewRepresentable` for reliable
/// touch-down/up detection. SwiftUI's `DragGesture(minimumDistance: 0)` conflicts
/// with scroll gestures and is unreliable for hold-to-record patterns.
struct RecordButton: View {
    @Environment(AppState.self) private var appState
    @State private var isPressed = false
    @State private var pulseAnimation = false
    @State private var timer: Timer?

    private let buttonHeight: CGFloat = 120
    private let cornerRadius: CGFloat = 20

    var body: some View {
        ZStack {
            // Background fill
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(fillColor)

            // Border
            borderView

            // Content (icon + text)
            contentView
        }
        .frame(maxWidth: .infinity)
        .frame(height: buttonHeight)
        .overlay {
            HoldGestureView(
                onBegan: { startRecording() },
                onEnded: { stopRecording() }
            )
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: isPressed)
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
                    .frame(width: 22, height: 22)
                Text(formatDuration(appState.recordingDuration))
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(Color.recordingRed)
            }

        case .transcribing:
            HStack(spacing: 10) {
                ProgressView()
                    .tint(Color.processingAmber)
                Text("Transcribing...")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.processingAmber)
            }

        default:
            Image(systemName: "mic.fill")
                .font(.title2)
                .foregroundStyle(Color.accentTeal)
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
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            appState.recordingDuration += 0.1
        }
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

// MARK: - Hold Gesture (UIKit Bridge)

/// Wraps `UILongPressGestureRecognizer` for reliable touch-down/up detection.
struct HoldGestureView: UIViewRepresentable {
    let onBegan: () -> Void
    let onEnded: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let gesture = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleGesture(_:))
        )
        gesture.minimumPressDuration = 0
        view.addGestureRecognizer(gesture)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

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

        @objc func handleGesture(_ gesture: UILongPressGestureRecognizer) {
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
