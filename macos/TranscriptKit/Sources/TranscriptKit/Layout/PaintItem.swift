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
    ///
    /// `Comparable` over that declaration order, so that "which side of the band
    /// does this land on" is a comparison rather than a lookup table kept in step
    /// by hand.
    enum Phase: Int, CaseIterable, Comparable {

        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

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

        /// The whole order. The default slice, and the bounds any cut divides.
        static let all: ClosedRange<Phase> = .background ... .overlay

        /// The order divided at `cuts`: contiguous slices, in paint order,
        /// together covering every phase exactly once.
        ///
        /// **This is the only way slices are made**, and the reason is that the
        /// three ways a hand-assembled set can be wrong — a gap, an overlap, a
        /// pair in the wrong order — are all silent. A gap is content nothing
        /// draws; an overlap is content drawn twice; the wrong order inverts the
        /// paint model for the phases involved. None of them raises anything.
        ///
        /// Here they are not so much prevented as unreachable: the walk visits
        /// every phase once, in declaration order, and each one is appended to
        /// exactly one slice before it is emitted. A partition is what the loop
        /// *does*, not something it is checked against afterwards.
        ///
        /// A cut at the first phase, or one repeated, yields no empty slice —
        /// which is why callers can pass whatever cut they mean without first
        /// asking whether it lands anywhere useful.
        static func slices(cutAt cuts: Set<Phase>) -> [ClosedRange<Phase>] {
            var slices: [ClosedRange<Phase>] = []
            var pending: [Phase] = []

            for phase in allCases {
                if cuts.contains(phase), let first = pending.first, let last = pending.last {
                    slices.append(first...last)
                    pending = []
                }
                pending.append(phase)
            }
            if let first = pending.first, let last = pending.last {
                slices.append(first...last)
            }
            return slices
        }
    }

    enum Primitive {
        /// Typeset text at its top-left. One item per *block of text*, never
        /// per line — a two-thousand-line code block is one of these, and the
        /// text culls its own lines against `dirty`. Emitting per line would turn a list of
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
        _ text: TypesetText, at origin: CGPoint, phase: Phase = .content
    )
        -> PaintItem
    {
        PaintItem(phase: phase, primitive: .text(text, at: origin))
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
    ///
    /// `phases` is which slice of the order to play, and exists because a row's
    /// painting can be split across more than one composited surface — a CALayer
    /// that has to sit *below* the glyphs cannot be a sublayer of the layer the
    /// glyphs were drawn into, so the glyphs move to a surface above it and each
    /// surface plays its own slice. Between them the surfaces of one row cover
    /// every phase exactly once.
    ///
    /// **A range, not a list.** The walk is still driven by `allCases`, so the
    /// declaration order remains the paint order and the slice can only say *which*
    /// phases to play, never in what sequence. Taking a list instead — which this
    /// briefly did — hands that sequence to the caller, and a caller that passed
    /// `[.content, .background]` would paint a code card's fill over its own code
    /// with nothing to catch it. A `ClosedRange` has no such degree of freedom.
    func paint(in ctx: CGContext, dirty: CGRect, phases: ClosedRange<PaintItem.Phase>) {
        for phase in PaintItem.Phase.allCases where phases.contains(phase) {
            for item in self where item.phase == phase {
                item.primitive.paint(in: ctx, dirty: dirty)
            }
        }
    }
}

extension PaintItem.Primitive {

    fileprivate func paint(in ctx: CGContext, dirty: CGRect) {
        switch self {
        case .text(let text, let origin):
            text.draw(at: origin, in: ctx, dirty: dirty)

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
