import SwiftUI
import LocalSTTCore

/// Full history sheet, delegating to HistoryListView.
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
                    HistoryListView(
                        items: appState.history,
                        isCompact: false
                    )
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
}
