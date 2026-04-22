import AppKit
import SwiftUI

/// TextKit 侧的 list 渲染（被 ``MarkdownView`` 用作 ``MarkdownSegment/list`` 的
/// 视图）。和 NativeTranscript 侧 ``TranscriptListLayout`` 思路一致——marker 是
/// 独立的、不可选的视觉元素，不掺进正文的 text flow，所以复制/拖拽的选中
/// 区不会带出 marker 或前导 indent 字符。嵌套 list 通过 HStack + 递归 VStack
/// 天然处理缩进，不依赖 tab stop。
struct MarkdownListView: View {
    let list: MarkdownList
    @Environment(\.markdownTheme) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
        let metrics = MarkdownListMetrics.make(list: list, theme: theme)
        VStack(alignment: .leading, spacing: theme.l3Item) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { idx, item in
                MarkdownListItemRow(
                    item: item,
                    marker: metrics.markers[idx],
                    markerColumnWidth: metrics.markerColumnWidth,
                    gap: metrics.gap,
                    theme: theme,
                    onOpenURL: { openURL($0) })
            }
        }
    }
}

private struct MarkdownListItemRow: View {
    let item: MarkdownListItem
    let marker: NSAttributedString?
    let markerColumnWidth: CGFloat
    let gap: CGFloat
    let theme: MarkdownTheme
    let onOpenURL: (URL) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            // Marker 列固定宽度 + trailing 对齐：ordered list 的 "1." / "99."
            // 点号自然对齐到一列。`textSelection(.disabled)` 在 macOS 14+ 把
            // marker 排除在 Text 可选范围外——彻底不可选。
            if let marker {
                Text(AttributedString(marker))
                    .frame(width: markerColumnWidth, alignment: .trailing)
                    .textSelection(.disabled)
            } else {
                Color.clear.frame(width: markerColumnWidth)
            }
            Color.clear.frame(width: gap)
            VStack(alignment: .leading, spacing: theme.l3Item) {
                ForEach(Array(item.content.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .list(let nested):
            MarkdownListView(list: nested)
        case .paragraph, .heading, .blockquote:
            // 其余 block 降级走 attributed string。paragraph 是绝大多数场景；
            // heading / blockquote 出现在 list item 里极少，保留可读性即可，
            // 不追求样式完美（例如 blockquote 左竖条）。
            let builder = MarkdownAttributedBuilder(theme: theme)
            let attr = builder.build(blocks: [block])
            MarkdownTextView(
                attributed: attr,
                linkColor: theme.linkColor,
                onOpenURL: onOpenURL,
                inlineCodeHPadding: theme.inlineCodeHPadding,
                inlineCodeVPadding: theme.inlineCodeVPadding,
                inlineCodeCornerRadius: theme.inlineCodeCornerRadius)
        }
    }
}

/// 集中管理 marker 构造 + marker column 宽度——``MarkdownListView`` 和
/// ``TranscriptListContents`` 各有自己的路径，marker 外观逻辑通过这里
/// （实际是纯数据转换函数）保持一致。
@MainActor
enum MarkdownListMetrics {
    struct Result {
        let markers: [NSAttributedString?]
        let markerColumnWidth: CGFloat
        let gap: CGFloat
    }

    static func make(list: MarkdownList, theme: MarkdownTheme) -> Result {
        var markers: [NSAttributedString?] = []
        markers.reserveCapacity(list.items.count)
        var maxW: CGFloat = 0
        for (idx, item) in list.items.enumerated() {
            let m = marker(item: item, idx: idx, list: list, theme: theme)
            if let m { maxW = max(maxW, ceil(m.size().width)) }
            markers.append(m)
        }
        return Result(
            markers: markers,
            markerColumnWidth: maxW,
            gap: theme.bodyFontSize * 0.5)
    }

    static func marker(
        item: MarkdownListItem,
        idx: Int,
        list: MarkdownList,
        theme: MarkdownTheme
    ) -> NSAttributedString? {
        if let checkbox = item.checkbox {
            let font = NSFont.systemFont(
                ofSize: theme.bodyFontSize * 1.05, weight: .regular)
            let color: NSColor = checkbox == .checked
                ? theme.primaryColor
                : theme.secondaryColor
            return NSAttributedString(
                string: checkbox == .checked ? "☑" : "☐",
                attributes: [.font: font, .foregroundColor: color])
        }
        if list.ordered {
            let n = (list.startIndex ?? 1) + idx
            let font = NSFont.monospacedSystemFont(
                ofSize: theme.bodyFontSize, weight: .regular)
            return NSAttributedString(
                string: "\(n).",
                attributes: [.font: font, .foregroundColor: theme.secondaryColor])
        }
        return NSAttributedString(
            string: "•",
            attributes: [.font: theme.bodyFont, .foregroundColor: theme.secondaryColor])
    }
}
