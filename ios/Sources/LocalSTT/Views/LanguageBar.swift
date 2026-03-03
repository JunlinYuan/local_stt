import SwiftUI

/// Horizontal one-tap language selector bar.
///
/// Shows capsule buttons for AUTO, EN, FR, 中文. Replaces the two-tap dropdown menu
/// for faster language switching during dictation.
struct LanguageBar: View {
    @Binding var language: String

    private let options: [(label: String, code: String)] = [
        ("AUTO", ""),
        ("EN", "en"),
        ("FR", "fr"),
        ("中文", "zh"),
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.code) { option in
                Button {
                    language = option.code
                } label: {
                    Text(option.label)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            isSelected(option.code)
                                ? Color.accentTeal
                                : Color.appSurface,
                            in: Capsule()
                        )
                        .foregroundStyle(
                            isSelected(option.code)
                                ? Color.appBackground
                                : Color.textMuted
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: language)
    }

    /// Treat unknown language values (e.g. persisted "ja") as AUTO.
    private func isSelected(_ code: String) -> Bool {
        if code.isEmpty {
            // AUTO is selected if language is empty or doesn't match any button
            return language.isEmpty || !options.dropFirst().contains(where: { $0.code == language })
        }
        return language == code
    }
}
