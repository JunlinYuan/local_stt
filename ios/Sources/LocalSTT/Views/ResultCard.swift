import SwiftUI
import LocalSTTCore

/// Displays transcription result with copy indicator and metadata.
struct ResultCard: View {
    let result: TranscriptionResult
    var justCopied: Bool = false
    @State private var showCopied: Bool

    init(result: TranscriptionResult, justCopied: Bool = false) {
        self.result = result
        self.justCopied = justCopied
        self._showCopied = State(initialValue: justCopied)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Transcribed text
            Text(result.text)
                .font(.body)
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)

            // Metadata row
            HStack(spacing: 12) {
                // Language badge
                Text(result.language.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentTeal)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentTeal.opacity(0.15), in: Capsule())

                // Duration
                Label(result.formattedDuration, systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(Color.textMuted)

                // Processing time
                Label(result.formattedProcessingTime, systemImage: "bolt")
                    .font(.caption)
                    .foregroundStyle(Color.textMuted)

                Spacer()

                // Copy button / indicator
                if showCopied {
                    Label("Copied", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentTeal)
                } else {
                    Button {
                        #if canImport(UIKit)
                        UIPasteboard.general.string = result.text
                        #endif
                        withAnimation { showCopied = true }
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            withAnimation { showCopied = false }
                        }
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentTeal)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.appBorder, lineWidth: 1)
        )
        .onAppear {
            // Show "Copied" briefly then switch to copy button
            Task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation { showCopied = false }
            }
        }
    }
}
