import SwiftUI

/// Completion list for file/slash command completions.
struct CompletionListView: View {
    @Bindable var viewModel: CompletionState
    var onConfirm: (any CompletionItem) -> Void

    private let rowHeight: CGFloat = 24
    private let verticalInset: CGFloat = 4
    private let maxVisibleItems = 10
    /// One line of description text inside a selected row.
    private let detailLineHeight: CGFloat = 15
    /// Bottom breathing room under the in-row description.
    private let detailBottomPadding: CGFloat = 6

    /// Height a selected row gains to host its (up to two-line)
    /// description. Reserved at exactly two lines so moving between two
    /// commands that both have a description never resizes the popup.
    private var detailBlockHeight: CGFloat { detailLineHeight * 2 + detailBottomPadding }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    if let header = viewModel.headerText {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.badge.questionmark")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 13)
                            Text(header)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .frame(height: rowHeight)
                        .padding(.top, verticalInset)
                        .padding(.bottom, viewModel.items.isEmpty ? verticalInset : 0)
                    }

                    if viewModel.items.isEmpty {
                        if viewModel.headerText == nil {
                            emptyRow
                                .padding(.vertical, verticalInset)
                        }
                    } else {
                        ForEach(Array(viewModel.items.enumerated()), id: \.offset) { index, item in
                            completionRow(
                                item: item,
                                index: index,
                                isFirst: viewModel.headerText == nil && index == 0,
                                isLast: index == viewModel.items.count - 1
                            )
                            .id(index)
                        }
                    }
                }
            }
            .frame(height: listHeight)
            // The popup must resize instantly — no crossfade or slide when
            // items change or the selected row grows/shrinks its description.
            .animation(nil, value: viewModel.items.count)
            .animation(nil, value: viewModel.selectedIndex)
            .onChange(of: viewModel.selectedIndex) { _, newIndex in
                withAnimation(.easeInOut(duration: 0.1)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private var emptyRow: some View {
        HStack(spacing: 8) {
            switch viewModel.emptyReason {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, 13)
                Text("Loading…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            case .noMatches:
                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, 13)
                    Text("Loading…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } else {
                    Text("No matches")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 13)
                }
            case .noDirectory:
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 13)
                Text("Please select a working directory first")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(height: rowHeight)
    }

    @ViewBuilder
    private func completionRow(
        item: any CompletionItem, index: Int, isFirst: Bool, isLast: Bool
    )
        -> some View
    {
        let isSelected = index == viewModel.selectedIndex
        // Selected rows expand to show the command description inline,
        // right under the command name; the highlight covers both lines.
        VStack(alignment: .leading, spacing: 0) {
            commandLine(item: item)

            if isSelected, let detail = cleanedDetail(item) {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: detailLineHeight * 2,
                        alignment: .topLeading
                    )
                    .padding(.leading, textLeading(for: item))
                    .padding(.trailing, 8)
                    .padding(.bottom, detailBottomPadding)
            }
        }
        .padding(.top, isFirst ? verticalInset : 0)
        .padding(.bottom, isLast ? verticalInset : 0)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.selectedIndex = index
            onConfirm(item)
        }
    }

    /// The command-name line — icon (file/dir only) + optional source
    /// badge + display text.
    @ViewBuilder
    private func commandLine(item: any CompletionItem) -> some View {
        HStack(spacing: 0) {
            if let icon = item.displayIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .padding(.leading, 13)
            }

            if let badge = item.displayBadge, !badge.isEmpty {
                Text(badge)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(nsColor: .tertiaryLabelColor).opacity(0.15))
                    )
                    .padding(.leading, 6)
            }

            Text(item.displayText)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, textLeading(for: item))

            Spacer(minLength: 8)
        }
        .frame(height: rowHeight)
    }

    /// Leading inset for the row's primary text. Icon-bearing rows sit
    /// after the 16pt glyph; text-only rows (slash commands) take the
    /// icon's own 13pt leading so the column edge stays aligned.
    private func textLeading(for item: any CompletionItem) -> CGFloat {
        if item.displayIcon == nil && item.displayBadge == nil { return 13 }
        return item.displayBadge != nil ? 4 : 6
    }

    // MARK: - Description

    /// Cleaned description for `item`, or nil when it carries none. Only
    /// slash commands populate `displayDetail`, so the in-row description
    /// is effectively slash-only.
    private func cleanedDetail(_ item: any CompletionItem) -> String? {
        guard let raw = item.displayDetail else { return nil }
        // Trim, fold every whitespace run (incl. \n \t) into one space.
        let cleaned = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return cleaned.isEmpty ? nil : cleaned
    }

    /// The selected row's description, used to size the popup.
    private var selectedDetail: String? {
        let idx = viewModel.selectedIndex
        guard idx >= 0, idx < viewModel.items.count else { return nil }
        return cleanedDetail(viewModel.items[idx])
    }

    // MARK: - Layout

    private var displayCount: Int {
        if viewModel.headerText != nil && viewModel.items.isEmpty { return 0 }
        if viewModel.isLoading && viewModel.items.isEmpty { return 1 }
        return viewModel.items.isEmpty ? 1 : min(viewModel.items.count, maxVisibleItems)
    }

    private var listHeight: CGFloat {
        let headerH: CGFloat = viewModel.headerText != nil ? rowHeight : 0
        let contentH = CGFloat(displayCount) * rowHeight
        let detailH: CGFloat = selectedDetail != nil ? detailBlockHeight : 0
        return headerH + contentH + detailH + 2 * verticalInset
    }
}
