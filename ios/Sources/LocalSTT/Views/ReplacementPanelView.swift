import SwiftUI
import LocalSTTCore

/// Sheet for managing word replacement rules.
struct ReplacementPanelView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var fromText = ""
    @State private var toText = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                // Enable toggle
                Section {
                    Toggle("Enable replacements", isOn: Binding(
                        get: { appState.replacementsEnabled },
                        set: {
                            appState.replacementManager.isEnabled = $0
                            appState.syncReplacements()
                        }
                    ))
                }

                // Add section
                Section {
                    HStack(spacing: 8) {
                        TextField("From...", text: $fromText)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .frame(maxWidth: .infinity)

                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(Color.textMuted)

                        TextField("To...", text: $toText)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .frame(maxWidth: .infinity)

                        Button {
                            addRule()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(Color.accentTeal)
                        }
                        .disabled(
                            fromText.trimmingCharacters(in: .whitespaces).isEmpty ||
                            toText.trimmingCharacters(in: .whitespaces).isEmpty
                        )
                    }

                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                // Rules list
                Section {
                    ForEach(appState.replacementRules) { rule in
                        HStack {
                            Text(rule.from)
                                .font(.body)

                            Image(systemName: "arrow.right")
                                .font(.caption)
                                .foregroundStyle(Color.textMuted)

                            Text(rule.to)
                                .font(.body)
                                .foregroundStyle(Color.accentTeal)

                            Spacer()

                            Button {
                                _ = appState.replacementManager.removeRule(rule)
                                appState.syncReplacements()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2)
                                    .foregroundStyle(Color.textMuted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } footer: {
                    Text("\(appState.replacementRules.count)/\(ReplacementManager.maxRules) rules. Case-insensitive whole-word matching. Rules apply top-to-bottom.")
                }
            }
            .navigationTitle("Replacements")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func addRule() {
        let (success, error) = appState.replacementManager.addRule(from: fromText, to: toText)
        if success {
            fromText = ""
            toText = ""
            errorMessage = nil
            appState.syncReplacements()
        } else {
            errorMessage = error
        }
    }
}
