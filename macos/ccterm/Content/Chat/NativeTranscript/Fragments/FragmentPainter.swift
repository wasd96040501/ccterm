import AppKit
import CoreText

/// Stateless paint dispatch for ``Fragment``. Called once per fragment from
/// the base ``TranscriptRow.draw(in:bounds:)`` default implementation.
///
/// Implementation choices carry over verbatim from the row-specific
/// `draw(in:bounds:)` methods they're replacing — roundedRectPath,
/// dashed-border stroking, per-corner radius paths. Moving-not-rewriting
/// keeps visual parity byte-for-byte during migration.
@MainActor
enum FragmentPainter {

    static func paint(
        _ fragment: Fragment,
        row: TranscriptRow,
        in ctx: CGContext,
        bounds: CGRect
    ) {
        switch fragment {
        case .rect(let f):   paintRect(f, in: ctx)
        case .text(let f):   paintText(f, row: row, in: ctx)
        case .line(let f):   paintLine(f, in: ctx)
        case .table(let f):  paintTable(f, row: row, in: ctx)
        case .list(let f):   paintList(f, row: row, in: ctx)
        case .custom(let f): paintCustom(f, in: ctx)
        }
    }

    // MARK: - Rect

    private static func paintRect(_ f: RectFragment, in ctx: CGContext) {
        switch f.style {
        case .fill(let color, let radius):
            ctx.saveGState()
            ctx.setFillColor(color.cgColor)
            if radius > 0 {
                let path = CGPath(
                    roundedRect: f.frame,
                    cornerWidth: radius,
                    cornerHeight: radius,
                    transform: nil)
                ctx.addPath(path)
                ctx.fillPath()
            } else {
                ctx.fill(f.frame)
            }
            ctx.restoreGState()

        case .fillPerCorner(let color, let tl, let tr, let bl, let br):
            ctx.saveGState()
            ctx.setFillColor(color.cgColor)
            let path = roundedRectPath(
                rect: f.frame,
                topLeft: tl, topRight: tr,
                bottomLeft: bl, bottomRight: br)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.restoreGState()

        case .stroke(let color, let lineWidth, let dash, let radius):
            ctx.saveGState()
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(lineWidth)
            if !dash.isEmpty {
                ctx.setLineDash(phase: 0, lengths: dash)
            }
            if radius > 0 {
                let path = CGPath(
                    roundedRect: f.frame,
                    cornerWidth: radius,
                    cornerHeight: radius,
                    transform: nil)
                ctx.addPath(path)
                ctx.strokePath()
            } else {
                ctx.stroke(f.frame)
            }
            ctx.restoreGState()
        }
    }

    // MARK: - Text

    private static func paintText(_ f: TextFragment, row: TranscriptRow, in ctx: CGContext) {
        let sel: NSRange? = f.selectionTag.flatMap { tag in
            let r = row.fragmentTextSelections[tag]
            if let r, r.location != NSNotFound, r.length > 0 { return r }
            return nil
        }
        f.layout.draw(origin: f.origin, selection: sel, in: ctx)
    }

    // MARK: - Line

    private static func paintLine(_ f: LineFragment, in ctx: CGContext) {
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: f.origin.x, y: f.baselineY)
        CTLineDraw(f.line, ctx)
        ctx.restoreGState()
    }

    // MARK: - Table

    private static func paintTable(_ f: TableFragment, row: TranscriptRow, in ctx: CGContext) {
        let sels: [[NSRange]]? = f.selectionTag.flatMap { row.fragmentTableSelections[$0] }
        f.layout.draw(origin: f.origin, selections: sels, in: ctx)
    }

    // MARK: - List

    private static func paintList(_ f: ListFragment, row: TranscriptRow, in ctx: CGContext) {
        let tag = f.selectionTag
        f.layout.draw(
            origin: f.origin,
            selectionResolver: { textIdx in
                guard let tag,
                      let map = row.fragmentListSelections[tag],
                      let r = map[textIdx],
                      r.location != NSNotFound, r.length > 0
                else { return nil }
                return r
            },
            in: ctx)
    }

    // MARK: - Custom

    private static func paintCustom(_ f: CustomFragment, in ctx: CGContext) {
        ctx.saveGState()
        f.draw(ctx, f.frame)
        ctx.restoreGState()
    }

    // MARK: - Path helper (per-corner radii)

    /// Ported verbatim from `AssistantMarkdownRow.roundedRectPath` — the
    /// code-block header strip (rounded top, square bottom) is the original
    /// consumer; exposing it here lets every `.fillPerCorner` fragment paint
    /// through the same math.
    private static func roundedRectPath(
        rect: CGRect,
        topLeft: CGFloat,
        topRight: CGFloat,
        bottomLeft: CGFloat,
        bottomRight: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + topLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topRight, y: rect.minY))
        if topRight > 0 {
            path.addArc(
                tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                tangent2End: CGPoint(x: rect.maxX, y: rect.minY + topRight),
                radius: topRight)
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight))
        if bottomRight > 0 {
            path.addArc(
                tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                tangent2End: CGPoint(x: rect.maxX - bottomRight, y: rect.maxY),
                radius: bottomRight)
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        path.addLine(to: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY))
        if bottomLeft > 0 {
            path.addArc(
                tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bottomLeft),
                radius: bottomLeft)
        } else {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeft))
        if topLeft > 0 {
            path.addArc(
                tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                tangent2End: CGPoint(x: rect.minX + topLeft, y: rect.minY),
                radius: topLeft)
        } else {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        }
        path.closeSubpath()
        return path
    }
}
