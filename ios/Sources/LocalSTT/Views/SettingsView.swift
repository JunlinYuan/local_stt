import SwiftUI
import LocalSTTCore

/// Settings screen — API key, language, vocabulary editor.
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey = ""
    @State private var showAPIKey = false
    @State private var isTesting = false
    @State private var testResult: Bool?
    @State private var vocabText = ""

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

                // Language Section
                Section("Language") {
                    Picker("Language", selection: Binding(
                        get: { appState.language },
                        set: { appState.language = $0 }
                    )) {
                        Text("Auto-detect").tag("")
                        Text("English").tag("en")
                        Text("Français").tag("fr")
                        Text("中文").tag("zh")
                        Text("日本語").tag("ja")
                    }
                }

                // Vocabulary Section
                Section {
                    TextEditor(text: $vocabText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 200)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    HStack {
                        let wordCount = vocabText
                            .components(separatedBy: .newlines)
                            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
                            .count

                        Text("\(wordCount)/\(VocabularyManager.maxVocabularySize) words")
                            .font(.caption)
                            .foregroundStyle(
                                wordCount > VocabularyManager.maxVocabularySize
                                    ? .red : Color.textMuted
                            )

                        Spacer()

                        Button("Save") {
                            saveVocabulary()
                        }
                    }
                } header: {
                    Text("Vocabulary")
                } footer: {
                    Text("One word/phrase per line. Lines starting with # are comments. Case is preserved (TEMPEST stays TEMPEST).")
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
                loadVocabularyText()
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

    private func loadVocabularyText() {
        vocabText = appState.vocabularyManager.words.joined(separator: "\n")
    }

    private func saveVocabulary() {
        let words = vocabText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        appState.vocabularyManager.setWords(words)
    }
}
