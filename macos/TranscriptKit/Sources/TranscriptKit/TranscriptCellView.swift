import AppKit

/// The cell view every row is served through: full row width, holding one
/// hosted view narrowed to the content width and centred.
///
/// The table frames this — `translatesAutoresizingMaskIntoConstraints` stays on,
/// which is what the table expects of a cell view and what turns this frame into
/// something the constraint engine can measure the hosted view against. The
/// hosted view inside is constraint-driven. Frame-positioned outer, Auto Layout
/// interior: the arrangement AppKit is built for, and the reason nothing here
/// competes with the table over a frame.
///
/// Centring lives here rather than in the table's own width because the scroll
/// view rewrites the document view's width back to the clip's on every tile —
/// measured, not assumed. It also can't live in each row's drawing code: a
/// hosted view is a constraint subtree, not something that can be asked to draw
/// itself at an offset.
///
/// Height is not decided here. Both edges pin to this view, whose height came
/// from `heightOfRow` by way of the table's row height — so the number flows
/// one way, down, and nothing in this view's constraints can produce a
/// different one. A hosted view whose own required constraints demand more
/// height than the row was given makes the system unsatisfiable, which AppKit
/// logs: the right outcome, since it means the delegate's height and the view's
/// content disagree.
@MainActor
final class TranscriptCellView: NSView {

    static let identifier = NSUserInterfaceItemIdentifier("TranscriptKit.cell")

    /// The view the host handed over for this row, still installed while the
    /// cell sits in the reuse pool — the two recycle as a pair, so a row coming
    /// back into view rebuilds no constraints.
    private(set) var hostedView: NSView?

    private var hostedWidth: NSLayoutConstraint?
    private var minContentWidth: CGFloat = 0
    private var maxContentWidth: CGFloat = .greatestFiniteMagnitude

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TranscriptCellView is code-only; init(coder:) is unavailable")
    }

    /// The content width a row `rowWidth` wide resolves to.
    ///
    /// One implementation, two callers: the transcript answers `heightOfRow`
    /// with it, and this view lays the hosted view out at it. Measuring and
    /// laying out at the same number is the whole point of it being one
    /// function.
    static func contentWidth(
        forRowWidth rowWidth: CGFloat, minWidth: CGFloat, maxWidth: CGFloat
    ) -> CGFloat {
        max(minWidth, min(maxWidth, rowWidth))
    }

    /// Installs `view` as this row's content, or leaves it in place when the
    /// pool handed back the cell it was already in.
    func install(_ view: NSView, minWidth: CGFloat, maxWidth: CGFloat) {
        minContentWidth = minWidth
        maxContentWidth = maxWidth

        if view !== hostedView {
            hostedView?.removeFromSuperview()
            hostedView = view
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            let width = view.widthAnchor.constraint(equalToConstant: bounds.width)
            hostedWidth = width
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: centerXAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
                width,
            ])
        }
        syncHostedWidth()
    }

    /// Re-clamps without touching the hosted view — the host changed the
    /// transcript's width bounds while this cell is on screen.
    func updateContentWidthBounds(minWidth: CGFloat, maxWidth: CGFloat) {
        minContentWidth = minWidth
        maxContentWidth = maxWidth
        syncHostedWidth()
    }

    /// The table writes this frame; the hosted view's width follows from it, so
    /// the constant is written here rather than in `layout()`.
    ///
    /// `layout()` runs while the engine is applying a solution it has already
    /// computed, so a constant written there is one solve too late — measured as
    /// a full pass of the row laid out at the previous content width.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncHostedWidth()
    }

    private func syncHostedWidth() {
        guard let hostedWidth else { return }
        let width = Self.contentWidth(
            forRowWidth: bounds.width, minWidth: minContentWidth, maxWidth: maxContentWidth)
        if hostedWidth.constant != width {
            hostedWidth.constant = width
        }
    }
}
