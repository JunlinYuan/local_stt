import SwiftUI

/// Hold-to-record button with visual state feedback.
///
/// Uses `UILongPressGestureRecognizer` via `UIViewRepresentable` for reliable
/// touch-down/up detection. SwiftUI's `DragGesture(minimumDistance: 0)` conflicts
/// with scroll gestures and is unreliable for hold-to-record patterns.
struct RecordButton: View {
    @Environment(AppState.self) private var appState
    @State private var isPressed = false
    @State private var pulseAnimation = false
    @State private var spinRotation: Double = 0
    @State private var timer: Timer?

    private let buttonSize: CGFloat = 120

    var body: some View {
        ZStack {
            // Outer ring
            outerRing

            // Inner circle
            Circle()
                .fill(innerColor)
                .frame(width: buttonSize - 24, height: buttonSize - 24)

            // Icon
            innerIcon
        }
        .frame(width: buttonSize, height: buttonSize)
        .overlay {
            HoldGestureView(
                onBegan: { startRecording() },
                onEnded: { stopRecording() }
            )
            .frame(width: buttonSize, height: buttonSize)
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
    private var outerRing: some View {
        switch appState.state {
        case .recording:
            Circle()
                .stroke(Color.recordingRed, lineWidth: 4)
                .frame(width: buttonSize, height: buttonSize)
                .scaleEffect(pulseAnimation ? 1.1 : 1.0)
                .opacity(pulseAnimation ? 0.6 : 1.0)
                .animation(
                    .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                    value: pulseAnimation
                )
                .onAppear { pulseAnimation = true }
                .onDisappear { pulseAnimation = false }

        case .transcribing:
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(Color.processingAmber, lineWidth: 4)
                .frame(width: buttonSize, height: buttonSize)
                .rotationEffect(.degrees(spinRotation))
                .animation(
                    .linear(duration: 1).repeatForever(autoreverses: false),
                    value: spinRotation
                )
                .onAppear { spinRotation = 360 }
                .onDisappear { spinRotation = 0 }

        default:
            Circle()
                .stroke(Color.accentTeal, lineWidth: 3)
                .frame(width: buttonSize, height: buttonSize)
        }
    }

    private var innerColor: Color {
        switch appState.state {
        case .recording: return Color.recordingRed.opacity(0.2)
        case .transcribing: return Color.processingAmber.opacity(0.15)
        default: return Color.accentTeal.opacity(0.1)
        }
    }

    @ViewBuilder
    private var innerIcon: some View {
        switch appState.state {
        case .recording:
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.recordingRed)
                .frame(width: 28, height: 28)

        case .transcribing:
            Image(systemName: "waveform")
                .font(.title)
                .foregroundStyle(Color.processingAmber)

        default:
            Image(systemName: "mic.fill")
                .font(.title)
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
