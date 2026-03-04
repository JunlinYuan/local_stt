import SwiftUI
import LocalSTTCore
import ServiceManagement

/// Settings window (Cmd+, preferences).
struct MacSettingsView: View {
    @Environment(MacAppState.self) private var appState

    @State private var apiKey = ""
    @State private var showAPIKey = false
    @State private var isTesting = false
    @State private var testResult: Bool?
    @State private var importExportStatus: String?

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            apiKeyTab
                .tabItem {
                    Label("API Key", systemImage: "key")
                }

            ffmTab
                .tabItem {
                    Label("Auto-Paste", systemImage: "cursorarrow.click.2")
                }
        }
        .frame(width: 450, height: 400)
        .onAppear {
            apiKey = appState.getAPIKey()
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Language") {
                Picker("Detection", selection: Binding(
                    get: { appState.language },
                    set: { appState.language = $0 }
                )) {
                    Text("Auto-detect").tag("")
                    Text("English").tag("en")
                    Text("French").tag("fr")
                    Text("Chinese").tag("zh")
                    Text("Japanese").tag("ja")
                }
                .pickerStyle(.segmented)
            }

            Section("Launch") {
                let canRegister = SMAppService.mainApp.status != .notFound
                Toggle("Launch at login", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            // Registration requires Developer ID signing
                        }
                    }
                ))
                .disabled(!canRegister)

                if !canRegister {
                    Text("Requires Developer ID code signing. Build with a signing certificate to enable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Data") {
                HStack {
                    Button("Export Vocab & Rules") {
                        exportData()
                    }

                    Button("Import Vocab & Rules") {
                        importData()
                    }
                }

                if let status = importExportStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Export or import vocabulary words and replacement rules as a JSON file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                HStack {
                    Text("Accessibility")
                    Spacer()
                    if GlobalHotkeyManager.checkAccessibility() {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else {
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                        .font(.caption)

                        Button("Refresh") {
                            appState.restartMonitors()
                        }
                        .font(.caption)
                        .help("Restart monitors after granting permission in System Settings")
                    }
                }

                Text("Required for global hotkey and auto-paste. If this app is listed but not working, remove it from the list and re-add it, then click Refresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - API Key Tab

    private var apiKeyTab: some View {
        Form {
            Section("Groq API Key") {
                HStack {
                    if showAPIKey {
                        TextField("gsk_...", text: $apiKey)
                            .font(.system(.body, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("gsk_...", text: $apiKey)
                            .font(.system(.body, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        showAPIKey.toggle()
                    } label: {
                        Image(systemName: showAPIKey ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                HStack {
                    Button("Save Key") {
                        appState.setAPIKey(apiKey)
                    }
                    .disabled(apiKey.isEmpty)

                    Spacer()

                    Button {
                        testAPIKey()
                    } label: {
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                        } else if let result = testResult {
                            Label(
                                result ? "Valid" : "Invalid",
                                systemImage: result ? "checkmark.circle.fill" : "xmark.circle.fill"
                            )
                            .foregroundStyle(result ? .green : .red)
                        } else {
                            Text("Test")
                        }
                    }
                    .disabled(apiKey.isEmpty || isTesting)
                }

                Text("Get your free API key from console.groq.com")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - FFM / Auto-Paste Tab

    private var ffmTab: some View {
        Form {
            Section("Focus Follows Mouse") {
                Toggle("Enable auto-paste", isOn: Binding(
                    get: { appState.ffmEnabled },
                    set: {
                        appState.ffmEnabled = $0
                        appState.updateFFMSettings()
                    }
                ))

                Picker("Mode", selection: Binding(
                    get: { appState.ffmMode },
                    set: {
                        appState.ffmMode = $0
                        appState.updateFFMSettings()
                    }
                )) {
                    Text("Track only").tag("track_only")
                    Text("Raise on hover").tag("raise_on_hover")
                }
                .disabled(!appState.ffmEnabled)

                Text("Track only: pastes to window under cursor without raising it.\nRaise on hover: also raises windows as you hover over them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Timing") {
                HStack {
                    Text("Clipboard sync delay")
                    Spacer()
                    Text(String(format: "%.2fs", appState.clipboardSyncDelay))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { appState.clipboardSyncDelay },
                        set: { appState.clipboardSyncDelay = $0 }
                    ),
                    in: 0.0...0.5,
                    step: 0.01
                )
                .disabled(!appState.ffmEnabled)

                HStack {
                    Text("Paste delay")
                    Spacer()
                    Text(String(format: "%.2fs", appState.pasteDelay))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { appState.pasteDelay },
                        set: { appState.pasteDelay = $0 }
                    ),
                    in: 0.0...0.5,
                    step: 0.01
                )
                .disabled(!appState.ffmEnabled)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Data Export / Import

    private func exportData() {
        guard let data = appState.exportBulkData() else {
            importExportStatus = "Failed to generate export data"
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "localSTT-data.json"
        panel.title = "Export Vocabulary & Replacement Rules"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async {
                do {
                    try data.write(to: url)
                    importExportStatus = "Exported to \(url.lastPathComponent)"
                } catch {
                    importExportStatus = "Export failed: \(error.localizedDescription)"
                }
                scheduleStatusClear()
            }
        }
    }

    private func importData() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.title = "Import Vocabulary & Replacement Rules"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async {
                do {
                    let data = try Data(contentsOf: url)
                    let result = appState.importBulkData(data)
                    importExportStatus = result
                } catch {
                    importExportStatus = "Import failed: \(error.localizedDescription)"
                }
                scheduleStatusClear()
            }
        }
    }

    private func scheduleStatusClear() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            importExportStatus = nil
        }
    }

    // MARK: - Actions

    private func testAPIKey() {
        isTesting = true
        testResult = nil

        let serviceToTest = GroqService(apiKey: apiKey)

        Task { @MainActor in
            let result = await serviceToTest.testConnection()
            isTesting = false
            testResult = result

            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                testResult = nil
            }
        }
    }
}
