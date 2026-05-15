import AppKit

/// Body layout for `Block.ToolGroupBlock.Child.webFetch` — one
/// rounded card carrying the response body verbatim. Glyphs use the
/// system body font (not monospaced) — `webFetch` results are
/// typically prose / markdown, and a proportional font reads more
/// naturally than the monospaced tier used by Bash / Grep / Glob.
///
/// `httpStatus` is intentionally not surfaced in the body — the
/// status reads in the header label (caller responsibility) and a
/// non-2xx error path drives the active/completed phrasing on the
/// group header instead.
///
/// `@unchecked Sendable`: holds `CTLine` references via embedded
/// `TextCardSection` values.
struct WebFetchChildLayout: @unchecked Sendable {
    let containerRect: CGRect
    let sections: [TextCardSection]

    var totalHeight: CGFloat { containerRect.height }

    nonisolated static func make(
        child: WebFetchChild,
        originX: CGFloat,
        originY: CGFloat,
        maxWidth: CGFloat
    ) -> WebFetchChildLayout {
        var specs: [TextCardSection.Spec] = []
        if let result = child.result {
            let trimmed = result.trimmingTrailingWhitespace
            if !trimmed.isEmpty {
                let attr = NSAttributedString(string: trimmed, attributes: [
                    .font: BlockStyle.paragraphFont,
                    .foregroundColor: NSColor.labelColor,
                ])
                specs.append(.init(text: "", attributed: attr))
            }
        }
        let (sections, height) = TextCardSection.build(
            specs: specs,
            originX: originX, originY: originY,
            maxWidth: maxWidth)
        let container = CGRect(
            x: originX, y: originY, width: maxWidth, height: height)
        return WebFetchChildLayout(
            containerRect: container, sections: sections)
    }

    func drawBackplate(in ctx: CGContext, origin: CGPoint) {
        TextCardSection.drawBackplates(sections, in: ctx, origin: origin)
    }

    func draw(in ctx: CGContext, origin: CGPoint) {
        TextCardSection.draw(sections, in: ctx, origin: origin)
    }
}
