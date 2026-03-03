import SwiftUI
import LocalSTTCore

/// Reusable scrollable history list with search and text highlighting.
///
/// Used both inline on the main screen (compact mode) and in the full
/// history sheet. In compact mode, uses a ScrollView with custom cards.
/// In full mode, uses a List for native swipe-to-delete.
///
/// Tapping any row copies its text to clipboard.
struct HistoryListView: View {
    @Environment(AppState.self) private var appState

    let items: [TranscriptionResult]
    var highlightedID: UUID? = nil
    var isCompact: Bool = true

    @State private var searchText = ""
    @State private var copiedID: UUID?

    private var filteredItems: [TranscriptionResult] {
        guard !searchText.isEmpty else { return items }
        return items.filter {
            $0.text.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar (only when there are items)
            if !items.isEmpty {
                searchBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }

            if !items.isEmpty, filteredItems.isEmpty {
                noMatchesState
            } else if isCompact {
                compactList
            } else {
                fullList
            }
        }
    }

    // MARK: - Compact Mode (ScrollView + custom cards for inline embedding)

    private var compactList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(filteredItems) { item in
                    compactRow(item)
                        .padding(.horizontal, 16)
                        .onTapGesture { copyToClipboard(item) }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Full Mode (List with native swipe-to-delete)

    private var fullList: some View {
        List {
            ForEach(filteredItems) { item in
                fullRow(item)
                    .contentShape(Rectangle())
                    .onTapGesture { copyToClipboard(item) }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    appState.deleteHistoryItem(filteredItems[index])
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Copy Action

    private func copyToClipboard(_ item: TranscriptionResult) {
        #if canImport(UIKit)
        UIPasteboard.general.string = item.text
        #endif
        withAnimation(.easeInOut(duration: 0.2)) {
            copiedID = item.id
        }
        // Reset after brief flash
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            withAnimation { copiedID = nil }
        }
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(Color.textMuted)

            TextField("Search history...", text: $searchText)
                .font(.subheadline)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            if !searchText.isEmpty {
                Text("(\(filteredItems.count)/\(items.count))")
                    .font(.caption2)
                    .foregroundStyle(Color.textMuted)

                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.textMuted)
                }
            }
        }
        .padding(8)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Compact Row (card style with delete button, tap to copy)

    private func compactRow(_ item: TranscriptionResult) -> some View {
        HStack(spacing: 0) {
            // Teal left accent for highlighted item
            if item.id == highlightedID {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentTeal)
                    .frame(width: 3)
                    .padding(.vertical, 4)
                    .padding(.trailing, 8)
            }

            VStack(alignment: .leading, spacing: 6) {
                // Text with optional search highlighting
                if searchText.isEmpty {
                    Text(item.text)
                        .font(.subheadline)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(3)
                } else {
                    highlightedText(item.text)
                        .font(.subheadline)
                        .lineLimit(3)
                }

                // Metadata row
                HStack(spacing: 8) {
                    Text(item.language.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentTeal)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentTeal.opacity(0.15), in: Capsule())

                    Text(item.formattedDuration)
                        .font(.caption)
                        .foregroundStyle(Color.textMuted)

                    Text(item.relativeTimestamp)
                        .font(.caption)
                        .foregroundStyle(Color.textMuted)

                    Spacer()

                    // "Copied" flash feedback
                    if copiedID == item.id {
                        Text("Copied")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.accentTeal)
                            .transition(.opacity)
                    }

                    Button {
                        withAnimation {
                            appState.deleteHistoryItem(item)
                        }
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(Color.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(
            copiedID == item.id ? Color.accentTeal.opacity(0.08) : Color.appSurface,
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    copiedID == item.id ? Color.accentTeal.opacity(0.3) : Color.appBorder,
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
    }

    // MARK: - Full Row (plain row for List, supports native swipe-to-delete)

    private func fullRow(_ item: TranscriptionResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if searchText.isEmpty {
                Text(item.text)
                    .font(.body)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(3)
            } else {
                highlightedText(item.text)
                    .font(.body)
                    .lineLimit(3)
            }

            HStack(spacing: 8) {
                Text(item.language.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentTeal)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.accentTeal.opacity(0.15), in: Capsule())

                Text(item.formattedDuration)
                    .font(.caption)
                    .foregroundStyle(Color.textMuted)

                Text(item.relativeTimestamp)
                    .font(.caption)
                    .foregroundStyle(Color.textMuted)

                Spacer()

                // "Copied" flash feedback
                if copiedID == item.id {
                    Text("Copied")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.accentTeal)
                        .transition(.opacity)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Text Highlighting

    private func highlightedText(_ text: String) -> Text {
        guard !searchText.isEmpty else {
            return Text(text).foregroundColor(Color.textPrimary)
        }

        var result = Text("")
        var remaining = text[text.startIndex...]

        while let range = remaining.range(
            of: searchText,
            options: .caseInsensitive
        ) {
            // Text before match
            if remaining.startIndex < range.lowerBound {
                result = result + Text(remaining[remaining.startIndex..<range.lowerBound])
                    .foregroundColor(Color.textPrimary)
            }
            // Matched text
            result = result + Text(remaining[range])
                .foregroundColor(Color.accentTeal)
                .bold()
            remaining = remaining[range.upperBound...]
        }

        // Remaining text after last match
        if !remaining.isEmpty {
            result = result + Text(remaining)
                .foregroundColor(Color.textPrimary)
        }

        return result
    }

    // MARK: - Empty States

    private var noMatchesState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(Color.textMuted)
            Text("No matches for \"\(searchText)\"")
                .font(.subheadline)
                .foregroundStyle(Color.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
    }
}
