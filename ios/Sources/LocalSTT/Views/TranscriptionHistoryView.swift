import SwiftUI
import LocalSTTCore

/// History of past transcriptions with copy and delete.
struct TranscriptionHistoryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if appState.history.isEmpty {
                    ContentUnavailableView(
                        "No Transcriptions",
                        systemImage: "text.bubble",
                        description: Text("Your transcription history will appear here.")
                    )
                } else {
                    List {
                        ForEach(appState.history) { item in
                            historyRow(item)
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                appState.deleteHistoryItem(appState.history[index])
                            }
                        }
                    }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !appState.history.isEmpty {
                        Button("Clear All", role: .destructive) {
                            appState.clearHistory()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func historyRow(_ item: TranscriptionResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.text)
                .font(.body)
                .lineLimit(3)

            HStack(spacing: 8) {
                Text(item.language.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentTeal)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.accentTeal.opacity(0.15), in: Capsule())

                Text(item.formattedDuration)
                    .font(.caption)
                    .foregroundStyle(Color.textMuted)

                Text(item.relativeTimestamp)
                    .font(.caption)
                    .foregroundStyle(Color.textMuted)

                Spacer()

                Button {
                    #if canImport(UIKit)
                    UIPasteboard.general.string = item.text
                    #endif
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(Color.accentTeal)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}
