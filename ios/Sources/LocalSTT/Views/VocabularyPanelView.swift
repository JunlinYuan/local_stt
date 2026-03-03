import SwiftUI
import LocalSTTCore

/// Sheet for managing vocabulary words with usage count badges.
struct VocabularyPanelView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var newWord = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                // Add section
                Section {
                    HStack {
                        TextField("Add word or phrase...", text: $newWord)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit { addWord() }

                        Button {
                            addWord()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(Color.accentTeal)
                        }
                        .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                // Word list section
                Section {
                    ForEach(appState.vocabularyWords, id: \.self) { word in
                        HStack {
                            Text(word)
                                .font(.body)

                            Spacer()

                            // Usage count badge
                            let count = appState.vocabularyUsageCounts[word] ?? 0
                            if count > 0 {
                                Text("\(count)\u{00D7}")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(Color.textMuted)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.appSurface, in: Capsule())
                            }

                            Button {
                                _ = appState.vocabularyManager.removeWord(word)
                                appState.syncVocabulary()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2)
                                    .foregroundStyle(Color.textMuted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("Words (ordered by usage)")
                } footer: {
                    Text("\(appState.vocabularyWords.count)/\(VocabularyManager.maxVocabularySize) words")
                }
            }
            .navigationTitle("Vocabulary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func addWord() {
        let (success, error) = appState.vocabularyManager.addWord(newWord)
        if success {
            newWord = ""
            errorMessage = nil
            appState.syncVocabulary()
        } else {
            errorMessage = error
        }
    }
}
