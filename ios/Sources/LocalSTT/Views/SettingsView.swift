import SwiftUI
import LocalSTTCore

/// Settings screen — API key only (language/vocab moved to main screen).
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey = ""
    @State private var showAPIKey = false
    @State private var isTesting = false
    @State private var testResult: Bool?

    var body: some View {
        NavigationStack {
            Form {
                // API Key Section
                Section {
                    HStack {
                        if showAPIKey {
                            TextField("gsk_...", text: $apiKey)
                                .font(.system(.body, design: .monospaced))
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        } else {
                            SecureField("gsk_...", text: $apiKey)
                                .font(.system(.body, design: .monospaced))
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }

                        Button {
                            showAPIKey.toggle()
                        } label: {
                            Image(systemName: showAPIKey ? "eye.slash" : "eye")
                                .foregroundStyle(Color.textMuted)
                        }
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
                } header: {
                    Text("Groq API Key")
                } footer: {
                    Text("Get your free API key from console.groq.com")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                apiKey = appState.getAPIKey()
            }
        }
    }

    // MARK: - Actions

    private func testAPIKey() {
        isTesting = true
        testResult = nil

        // Test with a temporary service — don't overwrite the saved key
        let serviceToTest = GroqService(apiKey: apiKey)

        Task {
            let result = await serviceToTest.testConnection()
            isTesting = false
            testResult = result

            // Reset after 3s
            Task {
                try? await Task.sleep(for: .seconds(3))
                testResult = nil
            }
        }
    }
}
