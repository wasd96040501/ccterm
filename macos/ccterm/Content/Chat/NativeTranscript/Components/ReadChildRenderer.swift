import AgentSDK
import AppKit
import CoreText

/// 富化 Read child —— 展开态用 group header 同款字体 / 颜色画一行
/// title("Read foo.swift" / "Reading foo.swift"),没有 chevron、没有交互。
/// 第一步刻意不做内嵌再展开。
enum ReadChildRenderer: GroupChildRenderer {

    struct Content: @unchecked Sendable {
        /// 标题文字 —— 展开态 child 用 completed 形式(`Read foo.swift`)。
        /// 选词理由见 ``readTitle(_:)``。
        let title: String
        let titleLine: CTLine
        let titleWidth: CGFloat
        let titleAscent: CGFloat
        let titleDescent: CGFloat
    }

    struct Frame: Sendable {
        /// row-local 全宽 frame —— 高度 = `groupChildHeaderHeight`。
        let rect: CGRect
        /// title 在 frame 内的 baseline 位置(相对 rect.origin)。
        let titleRect: CGRect
    }

    /// `parse` 只接受 `.Read`;非 Read 类型走 `PlaceholderChildRenderer` 兜底。
    /// 调用方(`GroupChildDispatch.parse`)在 switch 里保证传 Read。这里再防御性
    /// 处理一次,避免 force-unwrap 在 fixture / 单测里炸。
    nonisolated static func parse(_ tool: ToolUse, theme: TranscriptTheme) -> Content {
        let title = readTitle(tool)
        let attrs: [NSAttributedString.Key: Any] = [.font: theme.groupTitleFont]
        let str = NSAttributedString(string: title, attributes: attrs)
        let line = CTLineCreateWithAttributedString(str)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return Content(
            title: title,
            titleLine: line,
            titleWidth: CGFloat(width),
            titleAscent: ascent,
            titleDescent: descent)
    }

    nonisolated static func contentHash(_ tool: ToolUse, theme: TranscriptTheme) -> Int {
        var h = Hasher()
        h.combine("read")
        h.combine(readTitle(tool))
        return h.finalize()
    }

    nonisolated static func layout(
        _ content: Content,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        theme: TranscriptTheme
    ) -> Frame {
        let h = theme.groupChildHeaderHeight
        let outer = CGRect(x: x, y: y, width: width, height: h)
        // 文字垂直居中——跟 group header 同算法,baseline 居中行高。
        let titleH = content.titleAscent + content.titleDescent
        let clampedWidth = min(content.titleWidth, width)
        let titleRect = CGRect(
            x: outer.minX,
            y: outer.midY - titleH / 2,
            width: clampedWidth,
            height: titleH)
        return Frame(rect: outer, titleRect: titleRect)
    }

    nonisolated static func height(_ frame: Frame) -> CGFloat {
        frame.rect.height
    }

    @MainActor
    static func draw(
        _ content: Content,
        frame: Frame,
        theme: TranscriptTheme,
        in ctx: CGContext
    ) {
        let titleRect = frame.titleRect
        let baselineY = titleRect.maxY - content.titleDescent

        // 重新构造带 foregroundColor 的 CTLine —— parse 阶段只塞了 font,
        // 颜色在这里加(避免 CTLine 缓存进 cache 时锁死颜色,无法跟随 theme)。
        let attrs: [NSAttributedString.Key: Any] = [
            .font: theme.groupTitleFont,
            .foregroundColor: theme.groupTitleColor,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: content.title, attributes: attrs))

        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: titleRect.minX, y: baselineY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// `Reading foo.swift`(active) / `Read foo.swift`(completed)。
    /// active vs completed 由 GroupComponent 整体 isActive 驱动 ——
    /// `parse` 拿到的 ToolUse 自身没 active 标记,我们靠 `activeFragment` /
    /// `completedFragment` 两个 string 各 cache 一份,通过 contentHash 包进
    /// GroupComponent.contentHash 让 cache 自动 invalidate。
    /// 第一步 MVP:Read child 在 active group 用 activeFragment,在 completed
    /// group 用 completedFragment —— 这个判断在 GroupChildDispatch 拿不到
    /// isActive,所以 Read child 直接展示 completedFragment(展开态都是历史
    /// child,active 的 last 在 header 里已经体现)。
    private nonisolated static func readTitle(_ tool: ToolUse) -> String {
        // 展开态 child 永远展示 completed 形式 —— 原因:展开后用户已知道在
        // active group(header shimmer + active title 在画),child 列表是
        // "已经/正在被处理的文件清单",过去式更易扫读;active 进行时由
        // header 反映即可。
        tool.completedFragment ?? "[\(tool.caseName)]"
    }
}
