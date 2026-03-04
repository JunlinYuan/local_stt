import SwiftUI
import LocalSTTCore

/// Sheet for managing vocabulary words on macOS.
struct MacVocabularyView: View {
    @Environment(MacAppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var newWord = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Vocabulary")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()

            Divider()

            // Add word bar
            HStack {
                TextField("Add word or phrase...", text: $newWord)
                    .textFieldStyle(.plain)
                    .onSubmit { addWord() }

                Button {
                    addWord()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Color.accentTeal)
                }
                .buttonStyle(.plain)
                .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
            }

            Divider()

            // Word list
            if appState.vocabularyWords.isEmpty {
                VStack(spacing: 8) {
                    Text("No vocabulary words")
                        .font(.subheadline)
                        .foregroundStyle(Color.textMuted)
                    Text("Add words to ensure correct casing in transcriptions")
                        .font(.caption)
                        .foregroundStyle(Color.textMuted.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(appState.vocabularyWords, id: \.self) { word in
                        HStack {
                            Text(word)
                                .font(.body)

                            Spacer()

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
                }
                .listStyle(.plain)
            }

            // Footer
            Divider()
            HStack {
                Text("\(appState.vocabularyWords.count)/\(VocabularyManager.maxVocabularySize) words")
                    .font(.caption)
                    .foregroundStyle(Color.textMuted)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .preferredColorScheme(.dark)
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
