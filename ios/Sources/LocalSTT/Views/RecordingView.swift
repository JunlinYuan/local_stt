import SwiftUI
import LocalSTTCore

/// Main push-to-talk screen with bottom-anchored record button and inline history.
///
/// Layout (top to bottom):
///   1. History list (scrollable, fills available space)
///   2. Language bar + Vocab/Replace chips
///   3. Status messages (error/result/tooShort)
///   4. Record button (large rectangle, anchored near bottom)
///   5. Bottom padding (for home indicator swipe)
struct RecordingView: View {
    @Environment(AppState.self) private var appState
    @State private var showSettings = false
    @State private var showVocabPanel = false
    @State private var showReplacePanel = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    // History fills available space at top
                    HistoryListView(
                        items: appState.history,
                        highlightedID: latestResultID,
                        isCompact: true
                    )
                    .frame(maxHeight: .infinity)

                    // Status area (error / result / tooShort)
                    statusArea

                    // Record button (large rectangle)
                    RecordButton()
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)

                    // Language bar (below button)
                    LanguageBar(language: Binding(
                        get: { appState.language },
                        set: { appState.language = $0 }
                    ))
                    .padding(.bottom, 6)

                    // Quick-access chips (bottom)
                    quickAccessChips
                        .padding(.bottom, 34)
                }
                .frame(maxWidth: 480) // iPad constraint
            }
            .animation(.easeInOut(duration: 0.3), value: appState.state)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(Color.textMuted)
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showVocabPanel) {
                VocabularyPanelView()
            }
            .sheet(isPresented: $showReplacePanel) {
                ReplacementPanelView()
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Quick Access Chips

    private var quickAccessChips: some View {
        HStack(spacing: 10) {
            Button {
                showVocabPanel = true
            } label: {
                HStack(spacing: 4) {
                    Text("VOCAB")
                    Text("(\(appState.vocabularyWords.count))")
                        .foregroundStyle(Color.textMuted)
                }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.appSurface, in: Capsule())
                .foregroundStyle(Color.textPrimary)
            }
            .buttonStyle(.plain)

            Button {
                showReplacePanel = true
            } label: {
                HStack(spacing: 4) {
                    Text("REPLACE")
                    Text("(\(appState.replacementRules.count))")
                        .foregroundStyle(Color.textMuted)
                }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.appSurface, in: Capsule())
                .foregroundStyle(Color.textPrimary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Status Area

    /// Shows feedback for error/result/tooShort states only.
    /// Recording and transcribing states are displayed on the button itself.
    @ViewBuilder
    private var statusArea: some View {
        switch appState.state {
        case .tooShort:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.processingAmber)
                Text("Recording too short")
                    .font(.caption)
                    .foregroundStyle(Color.processingAmber)
            }
            .padding(.bottom, 8)

        case .result:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentTeal)
                Text("Copied to clipboard")
                    .font(.caption)
                    .foregroundStyle(Color.accentTeal)
            }
            .padding(.bottom, 8)

        case .error(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

        default:
            EmptyView()
        }
    }

    // MARK: - Helpers

    /// ID of the latest result for highlighting in history.
    private var latestResultID: UUID? {
        if case .result(let result) = appState.state {
            return result.id
        }
        return nil
    }
}
