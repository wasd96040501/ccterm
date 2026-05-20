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

    func drawBackplate(
        in ctx: CGContext, origin: CGPoint, dirtyRect: CGRect? = nil
    ) {
        body.drawBackplate(in: ctx, origin: origin, dirtyRect: dirtyRect)
    }

    func draw(in ctx: CGContext, origin: CGPoint, dirtyRect: CGRect? = nil) {
        body.draw(in: ctx, origin: origin, dirtyRect: dirtyRect)
    }

    nonisolated static func make(
        child: FileEditChild,
        lineMap: [String: [SyntaxToken]]?,
        originX: CGFloat,
        originY: CGFloat,
        maxWidth: CGFloat
    ) -> FileEditChildLayout {
        FileEditChildLayout(
            body: DiffLayout.make(
                diff: child.diff,
                lineMap: lineMap,
                // Per-child id keys cell-side hover / copied feedback.
                // Stable across re-layouts because `FileEditChild.id`
                // is caller-supplied, not derived from content.
                copyButtonId: child.id,
                // Copy payload = the post-edit content. Most useful
                // for a user clicking "copy" on a diff — they want
                // the file after the change, not the diff syntax.
                copyText: child.diff.newString,
                originX: originX,
                originY: originY,
                maxWidth: maxWidth))
    }
}
