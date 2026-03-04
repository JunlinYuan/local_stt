import AppKit
import SwiftUI
import LocalSTTCore

/// Scrollable history list with search, keyboard selection, and text highlighting for macOS.
///
/// Tapping any row or pressing Enter on a selected row copies its text to clipboard.
/// Keyboard: `/` search, `j`/`k` navigate, Enter copies, Esc clears selection.
struct MacHistoryView: View {
    @Environment(MacAppState.self) private var appState

    let items: [TranscriptionResult]
    var highlightedID: UUID? = nil

    /// Search text and focus state, owned by MainWindowView for keyboard shortcut access.
    @Binding var searchText: String
    var isSearchFocused: FocusState<Bool>.Binding

    /// Keyboard selection and copy feedback, owned by MainWindowView.
    @Binding var selectedIndex: Int?
    @Binding var copiedID: UUID?

    private var filteredItems: [TranscriptionResult] {
        guard !searchText.isEmpty else { return items }
        return items.filter {
            $0.text.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if items.isEmpty {
                emptyState
            } else {
                // Search bar
                searchBar
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                if filteredItems.isEmpty {
                    noMatchesState
                } else {
                    historyList
                }
            }
        }
    }

    // MARK: - History List

    private var historyList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                        historyRow(item, isSelected: index == selectedIndex)
                            .id(item.id)
                            .padding(.horizontal, 12)
                            .onTapGesture { copyToClipboard(item) }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: highlightedID) { _, newID in
                guard let id = newID else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo(id, anchor: .top)
                }
            }
            .onChange(of: selectedIndex) { _, newIndex in
                guard let idx = newIndex, idx < filteredItems.count else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(filteredItems[idx].id, anchor: .center)
                }
            }
        }
    }

    // MARK: - Row

    private func historyRow(_ item: TranscriptionResult, isSelected: Bool = false) -> some View {
        let isCopied = copiedID == item.id

        return HStack(spacing: 0) {
            // Teal left accent for highlighted (latest transcription) or keyboard-selected item
            if item.id == highlightedID || isSelected {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentTeal)
                    .frame(width: 3)
                    .padding(.vertical, 4)
                    .padding(.trailing, 8)
            }

            VStack(alignment: .leading, spacing: 5) {
                // Text with optional search highlighting
                if searchText.isEmpty {
                    Text(item.text)
                        .font(.system(.body))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                } else {
                    highlightedText(item.text)
                        .font(.system(.body))
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

                    // "Copied!" badge (instant flash)
                    if isCopied {
                        Text("Copied!")
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
        .padding(10)
        .background(
            isCopied ? Color.accentTeal.opacity(0.15)
            : isSelected ? Color.accentTeal.opacity(0.08)
            : Color.appSurface,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isCopied ? Color.accentTeal.opacity(0.3)
                    : isSelected ? Color.accentTeal.opacity(0.2)
                    : Color.appBorder,
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
    }

    // MARK: - Copy

    private func copyToClipboard(_ item: TranscriptionResult) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)

        // Instant highlight — no sweep, just flash
        copiedID = item.id

        // Quick fade out
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(.easeOut(duration: 0.15)) {
                if copiedID == item.id {
                    copiedID = nil
                }
            }
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
                .textFieldStyle(.plain)
                .focused(isSearchFocused)

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
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Text Highlighting

    private func highlightedText(_ text: String) -> Text {
        guard !searchText.isEmpty else {
            return Text(text).foregroundColor(Color.textPrimary)
        }

        var result = Text("")
        var remaining = text[text.startIndex...]

        while let range = remaining.range(of: searchText, options: .caseInsensitive) {
            if remaining.startIndex < range.lowerBound {
                result = result + Text(remaining[remaining.startIndex..<range.lowerBound])
                    .foregroundColor(Color.textPrimary)
            }
            result = result + Text(remaining[range])
                .foregroundColor(Color.accentTeal)
                .bold()
            remaining = remaining[range.upperBound...]
        }

        if !remaining.isEmpty {
            result = result + Text(remaining)
                .foregroundColor(Color.textPrimary)
        }

        return result
    }

    // MARK: - Empty States

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.largeTitle)
                .foregroundStyle(Color.textMuted.opacity(0.5))
            Text("No transcriptions yet")
                .font(.subheadline)
                .foregroundStyle(Color.textMuted)
            Text("Hold Left Control or click the button below to record")
                .font(.caption)
                .foregroundStyle(Color.textMuted.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

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
