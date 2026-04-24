import AppKit

/// Transcript-local visual tokens that build on top of `MarkdownTheme`.
///
/// `MarkdownTheme` already owns typography (fonts, sizes) and the generic
/// block-level paddings. `TranscriptTheme` adds the chat-specific layout
/// constants that the NativeTranscript renderer needs: row gutters, user
/// bubble geometry, etc.
struct TranscriptTheme {
    let markdown: MarkdownTheme

    // MARK: - Row layout

    /// Horizontal inset between the row content and the table view edges.
    var rowHorizontalPadding: CGFloat = 28
    /// Vertical space reserved above/below content inside each row. Two
    /// adjacent rows' v-paddings sum to the visible gap between them.
    var rowVerticalPadding: CGFloat = 12
    /// Upper bound for the row's layout width. Window 比这个宽时内容列固定该值
    /// 并居中，留白分到两侧；窄于该值时内容占满。
    var maxContentWidth: CGFloat = 780

    // MARK: - User bubble

    /// Minimum distance from the bubble's LEFT edge to the frame's left edge
    /// when the text content is long enough to wrap.
    var bubbleMinLeftGutter: CGFloat = 60
    /// Right-edge inset of the bubble from the frame's right edge.
    var bubbleRightInset: CGFloat = 20
    /// 气泡最大宽度上限。content 列上限 780，这里 560 ≈ 60ch @ body 14pt，
    /// 保留右侧视觉重心，避免长段落贴到左 gutter。
    var userBubbleMaxWidth: CGFloat = 560
    var bubbleHorizontalPadding: CGFloat = 16
    var bubbleVerticalPadding: CGFloat = 12
    var bubbleCornerRadius: CGFloat = 14

    var bubbleFillColor: NSColor {
        NSColor.controlAccentColor.withAlphaComponent(0.15)
    }

    // MARK: - User bubble collapse

    /// 行数 >= threshold + minHiddenLines 才折叠。
    var userBubbleCollapseThreshold: Int = 12
    /// 只隐 1~2 行体验差于直接全显，所以要满足 `lines.count > threshold + minHiddenLines - 1`
    /// = `lines.count >= threshold + minHiddenLines` 才折叠。
    var userBubbleMinHiddenLines: Int = 3
    /// Chevron glyph 绘制尺寸（边长）。
    var chevronSize: CGFloat = 10
    /// Chevron 点击命中区边长。mouseUp 分派优先走这个。
    var chevronHitSize: CGFloat = 20
    /// Chevron 右下 inset。Telegram `FoldingTextView` 的规则：inset 大于
    /// `cornerRadius` 让 chevron 的 bounding box 落在圆角之外的平面区。
    /// 我们 `bubbleCornerRadius=14` + `bubbleVerticalPadding=12` 决定了
    /// "inset > cornerRadius" 不可行（chevron 会撞到 text 底），取 10 作为
    /// 折中——距圆角 center 约 5.7pt，离弧 8pt，不压圆角；对 text 的视觉侵入
    /// 仅右下角 ~4pt（expanded 态少数行的 trailing 位置）。
    var chevronInset: CGFloat = 10
    /// 折叠态底部 gradient fade 的高度。
    var collapseFadeHeight: CGFloat = 20

    // MARK: - Placeholder (tool / group / thinking)

    var placeholderHeight: CGFloat = 36
    /// Placeholder 与正文共用同一条左右 gutter — 始终跟随 `rowHorizontalPadding`，
    /// 避免两个独立字段漂移。
    var placeholderHorizontalInset: CGFloat { rowHorizontalPadding }
    var placeholderVerticalInset: CGFloat = 4
    var placeholderCornerRadius: CGFloat = 6
    var placeholderLineDashPattern: [CGFloat] = [4, 3]
    var placeholderTextFont: NSFont {
        .systemFont(ofSize: 12, weight: .regular)
    }

    // MARK: - Code block (Stage 3 visual, but used by row height math in Stage 2)

    var codeBlockHorizontalPadding: CGFloat = 12
    var codeBlockVerticalPadding: CGFloat { markdown.blockPadding }
    var codeBlockCornerRadius: CGFloat { markdown.blockCornerRadius }

    // MARK: - Code block header (language label + click-to-copy)

    /// Height of the header bar drawn above each fenced code block.
    var codeBlockHeaderHeight: CGFloat = 24
    /// Left padding of the language label inside the header. Derived from
    /// the body padding so the label's first glyph sits on the same vertical
    /// line as the code underneath.
    var codeBlockHeaderLabelInsetX: CGFloat { codeBlockHorizontalPadding }
    /// Right padding of the copy icon inside the header.
    var codeBlockHeaderIconInsetX: CGFloat = 8
    /// Rendered side length of the copy icon (square glyph bounds).
    var codeBlockHeaderIconSize: CGFloat = 13
    var codeBlockHeaderFontSize: CGFloat = 11

    /// Header bar tint — a touch darker than the body so the split reads
    /// clearly in both schemes. Mirrors Telegram's `main.alpha(0.2)` trick
    /// but layered on top of the same body swatch.
    var codeBlockHeaderBackground: NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(white: 1, alpha: 0.06)
                : NSColor(white: 0, alpha: 0.05)
        }
    }

    var codeBlockHeaderForeground: NSColor { .secondaryLabelColor }

    static let `default` = TranscriptTheme(markdown: .default)
}

// MARK: - Sendable conformance

/// `TranscriptTheme` / `MarkdownTheme` 是包 `NSFont` / `NSColor` 的不可变值类型,
/// font/color 实例本身线程安全可读。`@unchecked` 让 theme 跨 `Task` 边界传递
/// 无需 boxing。
extension TranscriptTheme: @unchecked Sendable {}
extension MarkdownTheme: @unchecked Sendable {}
