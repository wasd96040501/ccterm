import AppKit
import CoreText

/// One stroke of painting, and how far back it sits.
///
/// A block does not *perform* its drawing; it **describes** it. `paint` walks the
/// tree and appends items to a list the caller owns, and the caller plays that
/// list back. The difference is the whole point: with an immediate `draw`, where
/// something lands is decided by *when the call happens*, and a call inside
/// another block's `draw` is somewhere nobody outside can reach. With a list,
/// where something lands is decided by a **number it carries**, and a number can
/// be attached by anyone.
///
/// That is what lets `BlockView` add a selection band that sits above a
/// code card's fill and below its glyphs without the code card knowing selection
/// exists — the band is simply tagged `.decoration`, and `.background` <
/// `.decoration` < `.content` settles it.
///
/// The vocabulary is **closed**, the way `MarkdownIR`'s is. A block that cannot
/// say what it wants with these primitives is a signal to stop and look at the
/// vocabulary, not a licence to slip in one more case — the whole value of a
/// closed set is that adding to it is a decision rather than a reflex.
///
/// Borrowed from WebKit's `RenderObject::PaintPhase` (a paint order is a
/// classification of the work, not a stage of a pipeline — nothing flows from one
/// phase to the next) and from the display lists that Skia and Blink record
/// instead of issuing context calls. What is *not* borrowed is inspectability:
/// these primitives carry `CTLine` and `NSColor`, so a list can be replayed but
/// not compared, serialised, or handed to another thread. Nothing here needs
/// that yet; when something does, that is the direction.
struct PaintItem {

    /// How far back a stroke sits. A sort key, not a pipeline stage — the
    /// closest analogue is a `z-index` quantised to four named tiers.
    ///
    /// Declaration order **is** the paint order, and `allCases` is what the
    /// player iterates.
    enum Phase: Int, CaseIterable {
        /// Opaque things behind text: a code card's fill, a table's row tints and
        /// dividers, a quote's bar.
        case background
        /// Selection bands, and later search hits and hover tints — above the
        /// background, below the glyphs, which is where `NSTextView` puts them so
        /// that anti-aliased glyphs blend against the highlight rather than
        /// against whatever was underneath it.
        case decoration
        /// Glyphs.
        case content
        /// Over the glyphs: a table's border, a code card's language chip.
        case overlay
    }

    enum Primitive {
        /// A typeset run at its top-left. One item per *run*, never per line —
        /// a two-thousand-line code block is one of these, and the run culls its
        /// own lines against `dirty`. Emitting per line would turn a list of
        /// dozens into a list of thousands.
        case text(TypesetText, at: CGPoint)

        case fill(CGRect, NSColor)
        case fillPath(CGPath, NSColor)
        case strokePath(CGPath, width: CGFloat, cap: CGLineCap, NSColor)
    }

    let phase: Phase
    let primitive: Primitive
}

// MARK: - Emitting

extension PaintItem {

    /// Defaults name the phase each primitive almost always belongs to, so a call
    /// site says the phase only where it is making a real choice — a selection
    /// band, a table's border.
    static func text(
        _ run: TypesetText, at origin: CGPoint, phase: Phase = .content
    )
        -> PaintItem
    {
        PaintItem(phase: phase, primitive: .text(run, at: origin))
    }

    static func fill(_ rect: CGRect, _ color: NSColor, phase: Phase = .background) -> PaintItem {
        PaintItem(phase: phase, primitive: .fill(rect, color))
    }

    static func fill(_ path: CGPath, _ color: NSColor, phase: Phase = .background) -> PaintItem {
        PaintItem(phase: phase, primitive: .fillPath(path, color))
    }

    static func stroke(
        _ path: CGPath, width: CGFloat, cap: CGLineCap = .butt, _ color: NSColor,
        phase: Phase = .overlay
    ) -> PaintItem {
        PaintItem(phase: phase, primitive: .strokePath(path, width: width, cap: cap, color))
    }

    /// A rounded rectangle, filled. Building the `CGPath` here rather than making
    /// it a primitive of its own keeps the vocabulary small: this runs once per
    /// block, not once per line, so the allocation is not on any hot path.
    static func fill(
        roundedRect rect: CGRect, radius: CGFloat, _ color: NSColor, phase: Phase = .background
    ) -> PaintItem {
        fill(
            CGPath(
                roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil),
            color, phase: phase)
    }

    static func stroke(
        roundedRect rect: CGRect, radius: CGFloat, width: CGFloat, _ color: NSColor,
        phase: Phase = .overlay
    ) -> PaintItem {
        stroke(
            CGPath(
                roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil),
            width: width, color, phase: phase)
    }
}

// MARK: - Playing back

extension Array where Element == PaintItem {

    /// Plays the list into `ctx`: phase by phase, and within a phase in the order
    /// the items were emitted.
    ///
    /// **Bucketed rather than sorted.** `sort` in Swift is not documented as
    /// stable, and order within a phase is load-bearing — a table emits its row
    /// fills and then its dividers, both `.background`, and the dividers have to
    /// land on top. Walking the phases costs a handful of passes over a list of
    /// dozens, which is nothing next to one `CTLineDraw`.
    func paint(in ctx: CGContext, dirty: CGRect) {
        for phase in PaintItem.Phase.allCases {
            for item in self where item.phase == phase {
                item.primitive.paint(in: ctx, dirty: dirty)
            }
        }
    }
}

extension PaintItem.Primitive {

    fileprivate func paint(in ctx: CGContext, dirty: CGRect) {
        switch self {
        case .text(let run, let origin):
            run.draw(at: origin, in: ctx, dirty: dirty)

        case .fill(let rect, let color):
            ctx.setFillColor(color.cgColor)
            ctx.fill(rect)

        case .fillPath(let path, let color):
            ctx.saveGState()
            ctx.setFillColor(color.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.restoreGState()

        case .strokePath(let path, let width, let cap, let color):
            ctx.saveGState()
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(width)
            ctx.setLineCap(cap)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }
}
