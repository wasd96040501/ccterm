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
    let marker: MarkdownListMarker?
    let markerColumnWidth: CGFloat
    let gap: CGFloat
    let theme: MarkdownTheme
    let onOpenURL: (URL) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            // Marker 列固定宽度 + trailing 对齐：ordered list 的 "1." / "99."
            // 点号自然对齐到一列。`textSelection(.disabled)` 在 macOS 14+ 把
            // marker 排除在 Text 可选范围外——彻底不可选。
            markerView
                .frame(width: markerColumnWidth, alignment: .trailing)
            Color.clear.frame(width: gap)
            VStack(alignment: .leading, spacing: theme.l3Item) {
                ForEach(Array(item.content.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
        }
    }

    @ViewBuilder
    private var markerView: some View {
        switch marker {
        case .text(let attr):
            Text(AttributedString(attr))
                .textSelection(.disabled)
        case .checkbox(let checked):
            // SF Symbol 比 Unicode ☑/☐ 视觉一致——后者 Apple 字体把 checked
            // 方框画得比 unchecked 更粗/更大，打断对齐。SwiftUI 路径用
            // `Image(systemName:)`；CoreText 路径用 `CGPath` 自绘（同尺寸、同
            // stroke）。两边都脱离字体字形的设计差异。
            Image(systemName: checked ? "checkmark.square" : "square")
                .font(.system(size: theme.bodyFontSize))
                .foregroundStyle(checked ? Color.primary : Color.secondary)
        case .none:
            Color.clear
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

/// 抽象后的 marker 形态：bullet / ordered 走 text 字形，checkbox 走专门类型，
/// 让 CoreText 路径能自绘（避免 SF Pro 的 ☑/☐ glyph 粗细不一致）、SwiftUI
/// 路径能用 SF Symbol。
enum MarkdownListMarker: Equatable {
    case text(NSAttributedString)
    case checkbox(checked: Bool)
}

/// 集中管理 marker 构造 + marker column 宽度——``MarkdownListView`` 和
/// ``TranscriptListContents`` 各有自己的路径，marker 外观逻辑通过这里
/// （实际是纯数据转换函数）保持一致。
@MainActor
enum MarkdownListMetrics {
    struct Result {
        let markers: [MarkdownListMarker?]
        let markerColumnWidth: CGFloat
        let gap: CGFloat
    }

    static func make(list: MarkdownList, theme: MarkdownTheme) -> Result {
        var markers: [MarkdownListMarker?] = []
        markers.reserveCapacity(list.items.count)
        var maxW: CGFloat = 0
        for (idx, item) in list.items.enumerated() {
            let m = marker(item: item, idx: idx, list: list, theme: theme)
            if let m { maxW = max(maxW, width(of: m, theme: theme)) }
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
    ) -> MarkdownListMarker? {
        if let checkbox = item.checkbox {
            return .checkbox(checked: checkbox == .checked)
        }
        if list.ordered {
            let n = (list.startIndex ?? 1) + idx
            let font = NSFont.monospacedSystemFont(
                ofSize: theme.bodyFontSize, weight: .regular)
            return .text(NSAttributedString(
                string: "\(n).",
                attributes: [.font: font, .foregroundColor: theme.secondaryColor]))
        }
        return .text(NSAttributedString(
            string: "•",
            attributes: [.font: theme.bodyFont, .foregroundColor: theme.secondaryColor]))
    }

    /// Marker 的 column 宽度——checkbox 是方形边长，text 是 typographic width。
    static func width(of marker: MarkdownListMarker, theme: MarkdownTheme) -> CGFloat {
        switch marker {
        case .text(let attr): return ceil(attr.size().width)
        case .checkbox: return checkboxSize(theme: theme)
        }
    }

    /// Checkbox 边长 = 0.95 × bodyFontSize。略小于字的 cap-height，视觉和正文
    /// 字母齐平；再大会压过字高、显得笨重。
    static func checkboxSize(theme: MarkdownTheme) -> CGFloat {
        theme.bodyFontSize * 0.95
    }
}
