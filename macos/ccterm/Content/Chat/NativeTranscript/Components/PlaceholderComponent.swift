import AgentSDK
import AppKit
import CoreText

/// 占位 row —— 工具调用 / thinking / group 提示。灰色虚线边框 + 中心 label 文本。
/// 宽度无关(固定高度),不响应交互,不可选。
enum PlaceholderComponent: TranscriptComponent {
    static let tag = "Placeholder"

    struct Input: Sendable {
        let stableId: StableId
        let label: String
    }

    struct Content: @unchecked Sendable {
        let label: String
        let labelLine: CTLine
        let labelAscent: CGFloat
        let labelDescent: CGFloat
    }

    struct Layout: HasHeight, @unchecked Sendable {
        let content: Content
        let cachedHeight: CGFloat
    }

    typealias State = Void
    typealias SideCar = EmptyRowSideCar

    // MARK: - Inputs

    /// group entry 或 assistant entry 的 tool_use block → 一条 placeholder input。
    /// assistant 其他 block(text / thinking)不关我的事。
    nonisolated static func inputs(
        from entry: MessageEntry,
        entryIndex: Int
    ) -> [IdentifiedInput<Input>] {
        switch entry {
        case .group(let group):
            let label = "[Tools × \(group.items.count)]"
            let stableId = StableId(entryId: group.id, locator: .whole)
            return [IdentifiedInput(
                stableId: stableId,
                entryIndex: entryIndex,
                blockIndex: 0,
                input: Input(stableId: stableId, label: label))]
        case .single(let single):
            guard case .remote(let message) = single.payload,
                  case .assistant(let assistant) = message else { return [] }
            let blocks = assistant.message?.content ?? []
            var out: [IdentifiedInput<Input>] = []
            for (idx, block) in blocks.enumerated() {
                if case .toolUse(let u) = block {
                    let stableId = StableId(entryId: single.id, locator: .block(idx))
                    let label = "[Tool: \(u.caseName)]"
                    out.append(IdentifiedInput(
                        stableId: stableId,
                        entryIndex: entryIndex,
                        blockIndex: idx,
                        input: Input(stableId: stableId, label: label)))
                }
            }
            return out
        }
    }

    // MARK: - Prepare

    nonisolated static func prepare(
        _ input: Input,
        theme: TranscriptTheme
    ) -> Content {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: theme.placeholderTextFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let str = NSAttributedString(string: input.label, attributes: attrs)
        let line = CTLineCreateWithAttributedString(str)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return Content(
            label: input.label,
            labelLine: line,
            labelAscent: ascent,
            labelDescent: descent)
    }

    nonisolated static func contentHash(
        _ input: Input,
        theme: TranscriptTheme
    ) -> Int {
        var h = Hasher()
        h.combine(input.label)
        h.combine(theme.markdown.fingerprint)
        return h.finalize()
    }

    // MARK: - Layout (fixed height, width-independent)

    nonisolated static func layout(
        _ content: Content,
        theme: TranscriptTheme,
        width: CGFloat,
        state: State
    ) -> Layout {
        Layout(
            content: content,
            cachedHeight: theme.placeholderHeight + 2 * theme.rowVerticalPadding)
    }

    // MARK: - Render

    @MainActor
    static func render(
        _ layout: Layout,
        state: State,
        theme: TranscriptTheme,
        in ctx: CGContext,
        bounds: CGRect
    ) {
        let content = layout.content
        let rect = CGRect(
            x: theme.placeholderHorizontalInset,
            y: theme.rowVerticalPadding + theme.placeholderVerticalInset,
            width: max(0, bounds.width - 2 * theme.placeholderHorizontalInset),
            height: theme.placeholderHeight - 2 * theme.placeholderVerticalInset)

        ctx.saveGState()
        ctx.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: theme.placeholderLineDashPattern)
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: theme.placeholderCornerRadius,
            cornerHeight: theme.placeholderCornerRadius,
            transform: nil)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()

        let baselineY = rect.midY + (content.labelAscent - content.labelDescent) / 2
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: rect.minX + 12, y: baselineY)
        CTLineDraw(content.labelLine, ctx)
        ctx.restoreGState()
    }
}
