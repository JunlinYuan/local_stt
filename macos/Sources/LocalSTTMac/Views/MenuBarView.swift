import SwiftUI
import LocalSTTCore

/// Menu bar popover content — status, recent transcription, quick actions.
struct MenuBarView: View {
    @Environment(MacAppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status header
            statusHeader
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Divider()

            // Recent transcription
            if let latest = appState.history.first {
                recentTranscription(latest)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                Divider()
            }

            // Actions
            VStack(spacing: 2) {
                menuButton("Show Window", icon: "macwindow") {
                    NSApp.setActivationPolicy(.regular)
                    openWindow(id: "main")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NSApp.activate()
                        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                            window.makeKeyAndOrderFront(nil)
                        }
                    }
                }

                menuButton("Settings...", icon: "gearshape") {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate()
                    openSettings()
                }

                if !appState.history.isEmpty {
                    menuButton("Clear History", icon: "trash") {
                        appState.clearHistory()
                    }
                }

                Divider()
                    .padding(.vertical, 4)

                menuButton("Quit LocalSTT", icon: "xmark.circle") {
                    NSApp.terminate(nil)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 280)
    }

    // MARK: - Status Header

    private var statusHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(statusText)
                .font(.subheadline.weight(.medium))

            Spacer()

            if appState.hasAPIKey {
                Text("API OK")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.green.opacity(0.15), in: Capsule())
            } else {
                Text("No API Key")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.15), in: Capsule())
            }
        }
    }

    private var statusColor: Color {
        switch appState.state {
        case .recording: return .red
        case .transcribing: return Color.processingAmber
        case .error: return .red
        default: return .green
        }
    }

    private var statusText: String {
        switch appState.state {
        case .recording: return "Recording..."
        case .transcribing: return "Transcribing..."
        case .error(let msg): return msg
        case .tooShort: return "Too short"
        case .result: return "Ready"
        case .ready: return "Ready"
        }
    }

    // MARK: - Recent Transcription

    private func recentTranscription(_ item: TranscriptionResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Latest")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.textMuted)

            Text(item.text)
                .font(.caption)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(3)

            HStack(spacing: 6) {
                Text(item.language.uppercased())
                    .font(.caption2)
                    .foregroundStyle(Color.accentTeal)
                Text(item.relativeTimestamp)
                    .font(.caption2)
                    .foregroundStyle(Color.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.text, forType: .string)
        }
    }

    // MARK: - Menu Button

    private func menuButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 16)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

}
