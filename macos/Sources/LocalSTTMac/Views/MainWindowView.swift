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

    // Keyboard navigation state
    @State private var selectedIndex: Int?
    @State private var copiedID: UUID?
    @State private var sheetSelectedIndex: Int?

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
                    isSearchFocused: $isSearchFocused,
                    selectedIndex: $selectedIndex,
                    copiedID: $copiedID
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
        // Prevent search field from auto-focusing when the app activates (e.g. via FFM hover).
        // Without this, hovering over LocalSTT's window steals keyboard focus to the search
        // field. Uses didBecomeActiveNotification (not didBecomeKey) so it only fires when
        // switching FROM another app, not when clicking within LocalSTT's own windows.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        .sheet(isPresented: $showVocabPanel) {
            MacVocabularyView(selectedIndex: $sheetSelectedIndex)
                .environment(appState)
                .frame(minWidth: 400, minHeight: 400)
        }
        .sheet(isPresented: $showReplacePanel) {
            MacReplacementsView(selectedIndex: $sheetSelectedIndex)
                .environment(appState)
                .frame(minWidth: 400, minHeight: 400)
        }
        .onChange(of: showVocabPanel) { _, isOpen in
            if isOpen { sheetSelectedIndex = nil }
        }
        .onChange(of: showReplacePanel) { _, isOpen in
            if isOpen { sheetSelectedIndex = nil }
        }
        .onChange(of: searchText) { _, _ in
            selectedIndex = nil
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

    // MARK: - Filtered History

    private var filteredHistory: [TranscriptionResult] {
        guard !searchText.isEmpty else { return appState.history }
        return appState.history.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
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

        // --- Esc priority chain ---
        if event.keyCode == 53 { // Esc
            // 1. Sheet text field active → unfocus (enter sheet nav mode)
            if (showVocabPanel || showReplacePanel) && isTextFieldActive {
                NSApp.keyWindow?.makeFirstResponder(nil)
                return true
            }
            // 2. Sheet open → close sheet
            if showVocabPanel {
                showVocabPanel = false
                return true
            }
            if showReplacePanel {
                showReplacePanel = false
                return true
            }
            // 3. selectedIndex set → clear selection
            if selectedIndex != nil {
                selectedIndex = nil
                return true
            }
            // 4. searchText non-empty → clear search
            if !searchText.isEmpty {
                searchText = ""
                return true
            }
            // 5. search focused → unfocus
            if isSearchFocused {
                isSearchFocused = false
                return true
            }
            return false
        }

        // --- Enter: copy selected/first item ---
        if event.keyCode == 36 { // Enter/Return
            // In search field: copy first result, unfocus, select index 0
            if isSearchFocused && !filteredHistory.isEmpty {
                copyHistoryItem(at: 0)
                isSearchFocused = false
                selectedIndex = 0
                return true
            }
            // With selection in main view (no sheet): copy selected history item
            if !showVocabPanel && !showReplacePanel,
               let idx = selectedIndex, idx < filteredHistory.count {
                copyHistoryItem(at: idx)
                return true
            }
            return false
        }

        // --- Sheet keyboard navigation (j/k/d/x) ---
        if (showVocabPanel || showReplacePanel) && !isTextFieldActive {
            switch key {
            case "j":
                let count = showVocabPanel ? appState.vocabularyWords.count : appState.replacementRules.count
                if count > 0 {
                    let current = sheetSelectedIndex ?? -1
                    sheetSelectedIndex = min(current + 1, count - 1)
                }
                return true
            case "k":
                if let current = sheetSelectedIndex, current > 0 {
                    sheetSelectedIndex = current - 1
                }
                return true
            case "d", "x":
                if let idx = sheetSelectedIndex {
                    deleteSheetItem(at: idx)
                }
                return true
            default: break
            }
            return false
        }

        // "/" focuses search — standard vim-style trigger
        if key == "/" && !isTextFieldActive && !showVocabPanel && !showReplacePanel {
            isSearchFocused = true
            selectedIndex = nil
            return true
        }

        // All remaining shortcuts require: no text field focused, no sheet open
        guard !isTextFieldActive,
              !showVocabPanel,
              !showReplacePanel
        else { return false }

        // j/k: navigate history
        switch key {
        case "j":
            if !filteredHistory.isEmpty {
                let current = selectedIndex ?? -1
                selectedIndex = min(current + 1, filteredHistory.count - 1)
            }
            return true
        case "k":
            if let current = selectedIndex, current > 0 {
                selectedIndex = current - 1
            }
            return true
        default: break
        }

        // Language shortcuts (j removed — use JA button; also require not recording/transcribing)
        if !appState.state.isRecordingOrTranscribing {
            switch key {
            case "a": appState.language = ""; return true
            case "e": appState.language = "en"; return true
            case "f": appState.language = "fr"; return true
            case "c": appState.language = "zh"; return true
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

    // MARK: - Copy & Delete Helpers

    private func copyHistoryItem(at index: Int) {
        guard index < filteredHistory.count else { return }
        let item = filteredHistory[index]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)
        copiedID = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(.easeOut(duration: 0.15)) {
                if copiedID == item.id { copiedID = nil }
            }
        }
    }

    private func deleteSheetItem(at index: Int) {
        if showVocabPanel {
            let words = appState.vocabularyWords
            guard index < words.count else { return }
            _ = appState.vocabularyManager.removeWord(words[index])
            appState.syncVocabulary()
            // Adjust selection
            if appState.vocabularyWords.isEmpty {
                sheetSelectedIndex = nil
            } else if index >= appState.vocabularyWords.count {
                sheetSelectedIndex = appState.vocabularyWords.count - 1
            }
        } else if showReplacePanel {
            let rules = appState.replacementRules
            guard index < rules.count else { return }
            _ = appState.replacementManager.removeRule(rules[index])
            appState.syncReplacements()
            // Adjust selection
            if appState.replacementRules.isEmpty {
                sheetSelectedIndex = nil
            } else if index >= appState.replacementRules.count {
                sheetSelectedIndex = appState.replacementRules.count - 1
            }
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
