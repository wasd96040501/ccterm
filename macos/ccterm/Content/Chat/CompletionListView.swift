import SwiftUI

/// Completion list for file/slash command completions.
struct CompletionListView: View {
    @Bindable var viewModel: CompletionViewModel
    var onConfirm: (any CompletionItem) -> Void
    var onDrillDown: ((any CompletionItem) -> Void)?
    var onDeleteRecent: ((any CompletionItem) -> Void)?

    private let rowHeight: CGFloat = 24
    private let maxVisibleItems = 10

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
                    }

                    if viewModel.items.isEmpty {
                        if viewModel.headerText == nil {
                            emptyRow
                        }
                    } else {
                        ForEach(Array(viewModel.items.enumerated()), id: \.offset) { index, item in
                            completionRow(item: item, index: index)
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
    private func completionRow(item: any CompletionItem, index: Int) -> some View {
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
                .padding(.leading, item.displayBadge != nil ? 4 : 6)

            Spacer(minLength: 8)

            if let detail = item.displayDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines).first, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.trailing, 8)
            }

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
        .background(index == viewModel.selectedIndex ? Color.accentColor.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.selectedIndex = index
            onConfirm(item)
        }
        .gesture(
            TapGesture()
                .modifiers(.control)
                .onEnded { _ in
                    viewModel.selectedIndex = index
                    onDrillDown?(item)
                }
        )
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
        if viewModel.headerText != nil && viewModel.items.isEmpty {
            return headerH
        }
        return headerH + contentH
    }
}
