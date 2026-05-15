import AppKit

/// Body layout for `Block.ToolGroupBlock.Child.grep` — renders a
/// filenames card (newline-joined) and, when present, a content
/// preview card. Both cards use `TextCardSection`'s shared chrome
/// (rounded 6pt card + monospaced body).
///
/// ```
/// ┌── containerRect ─────────────────────────────────┐
/// │ ╭──────────────────────────────────────────────╮ │  ← filenames card
/// │ │  src/Foo.swift                               │ │
/// │ │  src/Bar.swift                               │ │
/// │ ╰──────────────────────────────────────────────╯ │
/// │ ╭──────────────────────────────────────────────╮ │  ← content preview
/// │ │  src/Foo.swift:12: func main()               │ │
/// │ ╰──────────────────────────────────────────────╯ │
/// └──────────────────────────────────────────────────┘
/// ```
///
/// `@unchecked Sendable`: holds `CTLine` references via embedded
/// `TextCardSection` values.
struct GrepChildLayout: @unchecked Sendable {
    let containerRect: CGRect
    let sections: [TextCardSection]

    var totalHeight: CGFloat { containerRect.height }

    nonisolated static func make(
        child: GrepChild,
        originX: CGFloat,
        originY: CGFloat,
        maxWidth: CGFloat
    ) -> GrepChildLayout {
        var specs: [TextCardSection.Spec] = []
        if !child.filenames.isEmpty {
            specs.append(.init(text: child.filenames.joined(separator: "\n")))
        }
        if let content = child.content {
            specs.append(.init(text: content))
        }
        let (sections, height) = TextCardSection.build(
            specs: specs,
            originX: originX, originY: originY,
            maxWidth: maxWidth)
        let container = CGRect(
            x: originX, y: originY, width: maxWidth, height: height)
        return GrepChildLayout(
            containerRect: container, sections: sections)
    }

    func drawBackplate(in ctx: CGContext, origin: CGPoint) {
        TextCardSection.drawBackplates(sections, in: ctx, origin: origin)
    }

    func draw(in ctx: CGContext, origin: CGPoint) {
        TextCardSection.draw(sections, in: ctx, origin: origin)
    }
}
