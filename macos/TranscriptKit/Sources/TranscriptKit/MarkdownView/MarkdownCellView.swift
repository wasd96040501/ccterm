import AppKit

/// The view a self-drawn row is served through: holds one measured block and
/// draws it.
///
/// Deliberately thin. It owns no layout — the block arrived already measured at
/// the width the transcript committed to — and no styling. What it does own is
/// the two things a block cannot: a place in the view hierarchy, and the
/// `dirtyRect` that lets the block skip what cannot be seen.
///
/// `isFlipped` is true so that the y-down arithmetic every block is written in
/// matches the context it draws into, rather than being un-flipped at each of
/// the several dozen places a rectangle crosses the boundary.
final class MarkdownCellView: NSView {

    static let identifier = NSUserInterfaceItemIdentifier("TranscriptKit.block")

    private(set) var block: MarkdownBlock?

    override var isFlipped: Bool { true }

    /// Rows do not overlap and the transcript draws no background of its own, so
    /// AppKit can skip everything behind this view.
    override var isOpaque: Bool { false }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        // Layer-backed, and redrawn only when marked. Scrolling then composites
        // a rasterised bitmap rather than re-issuing `draw(_:)` for every strip
        // the clip view exposes, and the only thing that costs a repaint is
        // something actually saying the content changed.
        //
        // The counterpart obligation: AppKit's default policy for a `draw(_:)`
        // view redraws on resize, and this one explicitly does not — so every
        // resize that changes what should be on screen has to mark the view
        // itself. Nothing here is exempt from that, including a width change.
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MarkdownCellView is code-only; init(coder:) is unavailable")
    }

    /// Binds a measured block. Idempotent — a recycled instance keeps nothing
    /// from the row it was serving a moment ago, because the block is the
    /// entirety of its state.
    func configure(with block: MarkdownBlock) {
        self.block = block
        needsDisplay = true
    }

    /// Light ↔ dark flip, or the view joining a different appearance context.
    ///
    /// A repaint is the whole fix: blocks store `NSColor`s rather than resolved
    /// `CGColor`s, and both Core Text and `setFillColor` resolve them against the
    /// appearance current at draw time. Measured, not assumed — a tree built
    /// under light and drawn under dark is pixel-identical to one built under
    /// dark. So this costs one invalidation, and re-measuring would be wasted
    /// work.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let block, let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Collect, then play. The two steps are what let this view add strokes of
        // its own — a selection band, later a search hit — at a depth the blocks
        // decide, without reaching into any block's drawing. It appends an item
        // with a phase; the player puts it where that phase says.
        items.removeAll(keepingCapacity: true)
        block.paint(at: .zero, dirty: dirtyRect, into: &items)
        items.paint(in: ctx, dirty: dirtyRect)
    }

    /// Held across draws so the list's storage is allocated once rather than per
    /// repaint. Never read outside `draw(_:)`.
    private var items: [PaintItem] = []
}
