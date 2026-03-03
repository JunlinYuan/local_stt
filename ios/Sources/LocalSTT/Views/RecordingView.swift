import SwiftUI
import LocalSTTCore

/// Main push-to-talk screen.
struct RecordingView: View {
    @Environment(AppState.self) private var appState
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var timer: Timer?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Language picker
                    languagePicker
                        .padding(.top, 12)

                    Spacer()

                    // Waveform / status area
                    statusArea
                        .frame(height: 80)
                        .padding(.bottom, 24)

                    // Record button
                    RecordButton()
                        .padding(.bottom, 32)

                    // Result card
                    if case .result(let result) = appState.state {
                        ResultCard(result: result, justCopied: true)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .padding(.horizontal, 20)
                    }

                    if case .error(let message) = appState.state {
                        errorBanner(message)
                            .transition(.opacity)
                            .padding(.horizontal, 20)
                    }

                    Spacer()
                }
                .frame(maxWidth: 480) // iPad constraint
            }
            .animation(.easeInOut(duration: 0.3), value: appState.state)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showHistory = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(Color.textMuted)
                    }
                }
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
            .sheet(isPresented: $showHistory) {
                TranscriptionHistoryView()
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Language Picker

    private var languagePicker: some View {
        HStack {
            Spacer()
            Menu {
                Button("Auto-detect") { appState.language = "" }
                Divider()
                Button("English") { appState.language = "en" }
                Button("Français") { appState.language = "fr" }
                Button("中文") { appState.language = "zh" }
                Button("日本語") { appState.language = "ja" }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "globe")
                    Text(languageLabel)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .font(.subheadline)
                .foregroundStyle(Color.textMuted)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.appSurface, in: Capsule())
            }
            Spacer()
        }
    }

    private var languageLabel: String {
        switch appState.language {
        case "en": return "English"
        case "fr": return "Français"
        case "zh": return "中文"
        case "ja": return "日本語"
        default: return "Auto"
        }
    }

    // MARK: - Status Area

    @ViewBuilder
    private var statusArea: some View {
        switch appState.state {
        case .ready:
            Text("Hold to record")
                .font(.headline)
                .foregroundStyle(Color.textMuted)

        case .recording:
            VStack(spacing: 12) {
                WaveformView()
                Text(formatDuration(appState.recordingDuration))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Color.recordingRed)
            }

        case .transcribing:
            VStack(spacing: 8) {
                ProgressView()
                    .tint(Color.processingAmber)
                Text("Transcribing...")
                    .font(.subheadline)
                    .foregroundStyle(Color.processingAmber)
            }

        case .result:
            EmptyView()

        case .error:
            EmptyView()
        }
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
