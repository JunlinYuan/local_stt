import SwiftUI
import LocalSTTCore

/// Primary window layout: history list + recording area + controls.
struct MainWindowView: View {
    @Environment(MacAppState.self) private var appState
    @State private var showVocabPanel = false
    @State private var showReplacePanel = false
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    @State private var keyMonitor: Any?

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
                    highlightedID: latestResultID,
                    searchText: $searchText,
                    isSearchFocused: $isSearchFocused
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
            installKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
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

    // MARK: - Keyboard Shortcuts

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            return handleKeyEvent(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    /// Handle a key event. Returns `true` if consumed (swallowed), `false` to pass through.
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        // Skip events with Cmd/Option/Control modifiers — those are system shortcuts
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) || modifiers.contains(.option) || modifiers.contains(.control) {
            return false
        }

        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        // Check if a text field is focused (typing in search, sheets, etc.)
        let isTextFieldActive = NSApp.keyWindow?.firstResponder is NSText

        // Esc always handled (priority chain: close sheet → clear search → unfocus search)
        if event.keyCode == 53 { // Esc
            if showVocabPanel {
                showVocabPanel = false
                return true
            }
            if showReplacePanel {
                showReplacePanel = false
                return true
            }
            if !searchText.isEmpty {
                searchText = ""
                return true
            }
            if isSearchFocused {
                isSearchFocused = false
                return true
            }
            return false
        }

        // "/" focuses search — standard vim-style trigger
        if key == "/" && !isTextFieldActive && !showVocabPanel && !showReplacePanel {
            isSearchFocused = true
            return true
        }

        // All remaining shortcuts require: no text field focused, no sheet open, not recording
        guard !isTextFieldActive,
              !showVocabPanel,
              !showReplacePanel
        else { return false }

        // Language shortcuts (also require not recording/transcribing)
        if !appState.state.isRecordingOrTranscribing {
            switch key {
            case "a": appState.language = ""; return true
            case "e": appState.language = "en"; return true
            case "f": appState.language = "fr"; return true
            case "c": appState.language = "zh"; return true
            case "j": appState.language = "ja"; return true
            default: break
            }
        }

        // Panel shortcuts
        switch key {
        case "v": showVocabPanel = true; return true
        case "r": showReplacePanel = true; return true
        default: break
        }

        return false
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
        [("", "AUTO"), ("en", "EN"), ("fr", "FR"), ("zh", "ZH"), ("ja", "JA")]
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
