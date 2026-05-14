import AppKit

/// Body layout for a `Block.ToolGroupBlock.Child.fileEdit` entry. The
/// child's header band (file path + chevron) is owned by
/// `ToolGroupLayout`; this layout only renders the rounded hunks card
/// that appears below the header when the item is expanded.
///
/// All real work lives in `DiffLayout` — this file is the thin
/// `ToolGroupChildLayout`-shaped adaptor so the dispatcher enum has a
/// canonical place to land.
///
/// `@unchecked Sendable`: holds `CTLine` references via the contained
/// `DiffLayout`'s row array.
struct FileEditChildLayout: @unchecked Sendable {
    let body: DiffLayout

    var totalHeight: CGFloat { body.totalHeight }

    func drawBackplate(in ctx: CGContext, origin: CGPoint) {
        body.drawBackplate(in: ctx, origin: origin)
    }

    func draw(in ctx: CGContext, origin: CGPoint) {
        body.draw(in: ctx, origin: origin)
    }

    nonisolated static func make(
        child: FileEditChild,
        lineMap: [String: [SyntaxToken]]?,
        originX: CGFloat,
        originY: CGFloat,
        maxWidth: CGFloat
    ) -> FileEditChildLayout {
        FileEditChildLayout(body: DiffLayout.make(
            diff: child.diff,
            lineMap: lineMap,
            originX: originX,
            originY: originY,
            maxWidth: maxWidth))
    }
}
