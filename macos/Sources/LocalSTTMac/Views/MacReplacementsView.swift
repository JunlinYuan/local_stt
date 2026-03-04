import SwiftUI
import LocalSTTCore

/// Sheet for managing word replacement rules on macOS.
struct MacReplacementsView: View {
    @Environment(MacAppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var fromText = ""
    @State private var toText = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Replacements")
                    .font(.headline)

                Spacer()

                Toggle("Enabled", isOn: Binding(
                    get: { appState.replacementsEnabled },
                    set: {
                        appState.replacementManager.isEnabled = $0
                        appState.syncReplacements()
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)

                Button("Done") { dismiss() }
                    .padding(.leading, 8)
            }
            .padding()

            Divider()

            // Add rule bar
            HStack(spacing: 8) {
                TextField("From...", text: $fromText)
                    .textFieldStyle(.plain)
                    .frame(maxWidth: .infinity)

                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(Color.textMuted)

                TextField("To...", text: $toText)
                    .textFieldStyle(.plain)
                    .frame(maxWidth: .infinity)

                Button {
                    addRule()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Color.accentTeal)
                }
                .buttonStyle(.plain)
                .disabled(
                    fromText.trimmingCharacters(in: .whitespaces).isEmpty ||
                    toText.trimmingCharacters(in: .whitespaces).isEmpty
                )
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

            // Rules list
            if appState.replacementRules.isEmpty {
                VStack(spacing: 8) {
                    Text("No replacement rules")
                        .font(.subheadline)
                        .foregroundStyle(Color.textMuted)
                    Text("Add rules to auto-correct common misrecognitions")
                        .font(.caption)
                        .foregroundStyle(Color.textMuted.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
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
                }
                .listStyle(.plain)
            }

            // Footer
            Divider()
            HStack {
                Text("\(appState.replacementRules.count)/\(ReplacementManager.maxRules) rules. Case-insensitive whole-word matching.")
                    .font(.caption)
                    .foregroundStyle(Color.textMuted)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .preferredColorScheme(.dark)
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
