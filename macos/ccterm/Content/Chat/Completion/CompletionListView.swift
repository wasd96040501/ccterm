import SwiftUI

/// Completion list for file/slash command completions.
struct CompletionListView: View {
    @Bindable var viewModel: CompletionViewModel
    var onConfirm: (any CompletionItem) -> Void
    var onDeleteRecent: ((any CompletionItem) -> Void)?

    private let rowHeight: CGFloat = 24
    private let verticalInset: CGFloat = 4
    private let maxVisibleItems = 10
    /// Reserved height for the selected-item description footer. Fixed at
    /// two lines so navigating between commands of differing description
    /// length never resizes the popup — the footer height stays put.
    private let detailLineHeight: CGFloat = 15

    var body: some View {
        // The list keeps its own fixed-height scroll frame; the optional
        // description footer is a sibling below it. Splitting them this way
        // means the footer's appear/disappear changes the popup height
        // without disturbing the scroll geometry.
        VStack(spacing: 0) {
            list
            if let detail = selectedDetail {
                Divider()
                detailFooter(detail)
                    // Popup height changes (footer toggling, text reflow)
                    // must land instantly — no crossfade, no slide.
                    .transaction { $0.animation = nil }
            }
        }
    }

    private var list: some View {
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
            .animation(nil, value: viewModel.items.count)
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

            if let dirItem = item as? DirectoryCompletionItem, dirItem.isRecent {
                Text("recent")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .hoverCapsule(staticFill: Color(nsColor: .tertiaryLabelColor).opacity(0.15))

                Button {
                    onDeleteRecent?(item)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 16, height: 16)
                .padding(.trailing, 4)
            }
        }
        .frame(height: rowHeight)
        .padding(.top, isFirst ? verticalInset : 0)
        .padding(.bottom, isLast ? verticalInset : 0)
        .background(index == viewModel.selectedIndex ? Color.accentColor.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.selectedIndex = index
            onConfirm(item)
        }
    }

    /// Leading inset for the row's primary text. Icon-bearing rows sit
    /// after the 16pt glyph; text-only rows (slash commands) take the
    /// icon's own 13pt leading so the column edge stays aligned.
    private func textLeading(for item: any CompletionItem) -> CGFloat {
        if item.displayIcon == nil && item.displayBadge == nil { return 13 }
        return item.displayBadge != nil ? 4 : 6
    }

    // MARK: - Detail footer

    /// Cleaned description of the currently-selected item, or nil when the
    /// item carries none. Only slash commands populate `displayDetail`, so
    /// this footer is effectively slash-only.
    private var selectedDetail: String? {
        let idx = viewModel.selectedIndex
        guard idx >= 0, idx < viewModel.items.count else { return nil }
        guard let raw = viewModel.items[idx].displayDetail else { return nil }
        // Trim, fold every whitespace run (incl. \n \t) into one space.
        let cleaned = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return cleaned.isEmpty ? nil : cleaned
    }

    @ViewBuilder
    private func detailFooter(_ detail: String) -> some View {
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
            .padding(.horizontal, 13)
            .padding(.vertical, verticalInset)
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
        return headerH + contentH + 2 * verticalInset
    }
}
