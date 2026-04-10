import SwiftUI

/// Real-time audio level visualization as animated bars.
struct WaveformView: View {
    @Environment(AppState.self) private var appState

    private let barCount = 40
    private let barSpacing: CGFloat = 2

    @State private var levels: [CGFloat] = Array(repeating: 0, count: 40)

    var body: some View {
        HStack(alignment: .center, spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.recordingRed)
                    .frame(width: 3, height: max(3, levels[index] * 50))
                    .animation(.easeOut(duration: 0.08), value: levels[index])
            }
        }
        .frame(height: 50)
        .onChange(of: appState.recorder.currentRMS) { _, newRMS in
            // Shift bars left and add new value on the right
            var updated = levels
            updated.removeFirst()
            // Add slight randomness for visual interest
            let jitter = CGFloat.random(in: 0.8...1.2)
            updated.append(CGFloat(newRMS) * jitter)
            levels = updated
        }
        .onAppear {
            levels = Array(repeating: 0, count: barCount)
        }
    }
}
