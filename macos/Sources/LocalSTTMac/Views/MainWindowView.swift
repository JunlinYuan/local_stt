import SwiftUI
import LocalSTTCore

/// Primary window layout: history list + recording area + controls.
struct MainWindowView: View {
    @Environment(MacAppState.self) private var appState
    @State private var showVocabPanel = false
    @State private var showReplacePanel = false

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Permission banner — shown when Accessibility is not granted
                if !appState.accessibilityGranted {
                    accessibilityBanner
                }

                // History fills available space
                MacHistoryView(
                    items: appState.history,
                    highlightedID: latestResultID
                )
                .frame(maxHeight: .infinity)

                Divider()
                    .background(Color.appBorder)

                // Bottom recording area
                VStack(spacing: 10) {
                    // Waveform (visible when recording)
                    if case .recording = appState.state {
                        MacWaveformView()
                            .frame(height: 40)
                            .padding(.horizontal, 16)
                            .transition(.opacity)
                    }

                    // Status area
                    statusArea

                    // Record button
                    MacRecordButton()
                        .padding(.horizontal, 16)

                    // Language bar
                    languageBar
                        .padding(.bottom, 4)

                    // Quick-access chips
                    quickAccessChips
                        .padding(.bottom, 12)
                }
                .padding(.top, 10)
                .animation(.easeInOut(duration: 0.2), value: appState.state)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            appState.setupServices()
        }
        .sheet(isPresented: $showVocabPanel) {
            MacVocabularyView()
                .environment(appState)
                .frame(minWidth: 400, minHeight: 400)
        }
        .sheet(isPresented: $showReplacePanel) {
            MacReplacementsView()
                .environment(appState)
                .frame(minWidth: 400, minHeight: 400)
        }
    }

    // MARK: - Language Bar

    private var languageBar: some View {
        HStack(spacing: 6) {
            ForEach(languages, id: \.code) { lang in
                Button {
                    appState.language = lang.code
                } label: {
                    Text(lang.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(
                            appState.language == lang.code ? Color.accentTeal : Color.textMuted
                        )
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            appState.language == lang.code
                                ? Color.accentTeal.opacity(0.15)
                                : Color.appSurface,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var languages: [(code: String, label: String)] {
        [("", "AUTO"), ("en", "EN"), ("fr", "FR"), ("zh", "ZH")]
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
                .font(.caption.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
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
                .font(.caption.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.appSurface, in: Capsule())
                .foregroundStyle(Color.textPrimary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Status Area

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
            .padding(.bottom, 4)

        case .result:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentTeal)
                Text(appState.ffmEnabled ? "Pasted to target window" : "Copied to clipboard")
                    .font(.caption)
                    .foregroundStyle(Color.accentTeal)
            }
            .padding(.bottom, 4)

        case .error(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)

        default:
            EmptyView()
        }
    }

    // MARK: - Accessibility Banner

    private var accessibilityBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.lock.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility permission required")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.textPrimary)
                Text("Global hotkey and auto-paste won't work without it.")
                    .font(.caption2)
                    .foregroundStyle(Color.textMuted)
            }

            Spacer()

            Button("Open Settings") {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                )
            }
            .font(.caption)
            .buttonStyle(.borderedProminent)
            .tint(.orange)

            Button("Refresh") {
                appState.restartMonitors()
            }
            .font(.caption)
            .help("Click after granting permission in System Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) {
            Divider().background(Color.orange.opacity(0.3))
        }
    }

    // MARK: - Helpers

    private var latestResultID: UUID? {
        if case .result(let result) = appState.state {
            return result.id
        }
        return nil
    }
}
