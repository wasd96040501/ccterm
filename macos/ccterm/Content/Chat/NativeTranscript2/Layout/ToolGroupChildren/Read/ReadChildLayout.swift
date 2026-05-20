import AppKit

/// Body layout for `Block.ToolGroupBlock.Child.read`. When the
/// tool_result has landed and carries text (`ReadChild.content != nil`),
/// the body renders the file as a new-file `DiffLayout` — gutter line
/// numbers, no `+`/`-` chrome, per-line syntax highlighting. The header
/// band is owned by `ToolGroupLayout`; this layout only renders the
/// rounded card below it.
///
/// While the tool is still running (or the result carried no text)
/// `body == nil` and `totalHeight == 0`, so `ToolGroupLayout.make`
/// keeps the entry collapsed — same path the chevron-less `read`
/// previously took before it gained an expandable body.
///
/// `@unchecked Sendable`: holds `CTLine` references via the contained
/// `DiffLayout`'s row array.
struct ReadChildLayout: @unchecked Sendable {
    let body: DiffLayout?

    var totalHeight: CGFloat { body?.totalHeight ?? 0 }

    func drawBackplate(
        in ctx: CGContext, origin: CGPoint, dirtyRect: CGRect? = nil
    ) {
        body?.drawBackplate(in: ctx, origin: origin, dirtyRect: dirtyRect)
    }

    func draw(in ctx: CGContext, origin: CGPoint, dirtyRect: CGRect? = nil) {
        body?.draw(in: ctx, origin: origin, dirtyRect: dirtyRect)
    }

    nonisolated static func make(
        child: ReadChild,
        lineMap: [String: [SyntaxToken]]?,
        originX: CGFloat,
        originY: CGFloat,
        maxWidth: CGFloat
    ) -> ReadChildLayout {
        guard let content = child.content, !content.isEmpty else {
            return ReadChildLayout(body: nil)
        }
        // `oldString: nil` puts `DiffLayout` in new-file mode — every
        // line is demoted to `.context`, the sign column is dropped,
        // and the gutter is the only chrome left around the source
        // text. The block reads as "a viewable copy of the file"
        // rather than "a diff that's all additions".
        let diff = DiffBlock(
            filePath: child.filePath,
            oldString: nil,
            newString: content)
        return ReadChildLayout(
            body: DiffLayout.make(
                diff: diff,
                lineMap: lineMap,
                // Per-child id keys cell-side hover / copied feedback.
                copyButtonId: child.id,
                // Copy payload = the file contents the tool returned.
                copyText: content,
                originX: originX,
                originY: originY,
                maxWidth: maxWidth))
    }
}
