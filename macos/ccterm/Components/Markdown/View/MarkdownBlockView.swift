import AppKit

/// Base class for the self-drawn markdown block views. A plain `NSView` —
/// **not** an `NSTableCellView` — so a host can return it from
/// `tableView(_:viewFor:row:)`, stack it in an `NSStackView`, or mount it
/// standalone. Subclasses are one per block kind
/// (`MarkdownParagraphView`, `MarkdownCodeBlockView`, …), each owning its
/// own measure type; there is deliberately no shared layout abstraction
/// between them.
///
/// This class holds only the machinery that has nothing to do with which
/// kind is being drawn:
///
/// - **Layer-cached draw.** `wantsLayer` + `.onSetNeedsDisplay`, so a
///   scroll tick composites the cached bitmap instead of re-running Core
///   Text.
/// - **Centered content column.** The view's frame spans whatever width
///   the host gives it (a table row is full-width); `contentWidth` is the
///   width the subclass typeset at, and `contentOrigin` centers that
///   column in `bounds`. `draw(_:)` additionally clips to the column, so
///   a subclass **cannot** paint outside it.
/// - **Selection band.** Drawn under the glyphs, matching `NSTextView`'s
///   ordering, from the rects the subclass's `selectionAdapter` projects.
/// - **Cursor rects + click dispatch** over the subclass's
///   `interactiveHits`.
///
/// Subclasses override the six hooks below (`contentHeight`,
/// `measuredWidth`, `selectionAdapter`, `interactiveHits`, `iBeamRect`,
/// `drawBackplate`, `drawContent`) and expose their own
/// `configure(…)` + `nonisolated static` measure entry point.
class MarkdownBlockView: NSView {
    // MARK: - Host-supplied geometry

    /// Width the content was typeset at — the clip slot's width. The
    /// column is centered in `bounds`, so this is also what makes a
    /// full-width host row show a readable centered column.
    var contentWidth: CGFloat = 0 {
        didSet { if contentWidth != oldValue { contentGeometryChanged() } }
    }

    /// Padding above the content inside this view.
    var contentTopInset: CGFloat = 0 {
        didSet { if contentTopInset != oldValue { contentGeometryChanged() } }
    }

    /// Padding below the content inside this view. Only affects
    /// `intrinsicContentSize` (a table host answers row height itself).
    var contentBottomInset: CGFloat = 0 {
        didSet { if contentBottomInset != oldValue { invalidateIntrinsicContentSize() } }
    }

    /// Current selection inside this view, or `nil` for none. Derived
    /// state — a host re-applies it on reuse.
    var selection: SelectionRange? {
        didSet { if selection != oldValue { needsDisplay = true } }
    }

    /// Top-left of the content in view coords. Every draw / hit test /
    /// cursor rect goes through it, so they can never disagree about
    /// where the column sits.
    final var contentOrigin: CGPoint {
        CGPoint(x: (bounds.width - contentWidth) / 2, y: contentTopInset)
    }

    // MARK: - Subclass hooks

    /// Height of the drawn content at `contentWidth`, excluding insets.
    var contentHeight: CGFloat { 0 }

    /// Width the content actually typeset to. Never wider than
    /// `contentWidth`; a `DEBUG` assertion in `draw(_:)` catches a host
    /// that measured at a different width than it configured.
    var measuredWidth: CGFloat { 0 }

    /// Selection-facing geometry, or `nil` for a non-selectable kind
    /// (image, thematic break). The base view reads it only to paint the
    /// highlight band and to decide whether an I-beam applies.
    var selectionAdapter: SelectionAdapter? { nil }

    /// Interactive hot zones in content-local coords — links plus the
    /// view's own controls (copy button, chevron, image chips).
    var interactiveHits: [InteractiveHit] { [] }

    /// Region that should show the I-beam on hover, in content-local
    /// coords. `nil` means "the measured content rect" — matching
    /// `NSTextView`'s I-beam over its whole frame. Right-aligned kinds
    /// override it to confine the I-beam to their actual content.
    var iBeamRect: CGRect? { nil }

    /// Opaque chrome that must paint *before* the selection band so the
    /// highlight composites on top of it, under the glyphs. Default is a
    /// no-op — only the code block has an opaque card behind its text.
    func drawBackplate(in ctx: CGContext, origin: CGPoint) {}

    /// The kind-specific painting, in content-local coords offset by
    /// `origin`.
    func drawContent(in ctx: CGContext, origin: CGPoint) {}

    // MARK: - Init

    /// `required` so a host can dequeue generically
    /// (`makeRow(MarkdownParagraphView.self, …)`) instead of repeating the
    /// same reuse dance per kind.
    required override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: contentTopInset + contentHeight + contentBottomInset)
    }

    /// Call after re-measuring so the cached bitmap, the cursor rects and
    /// any intrinsic-height host all pick the new content up.
    final func contentDidChange() {
        invalidateIntrinsicContentSize()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private func contentGeometryChanged() {
        invalidateIntrinsicContentSize()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// Width-driven re-centering. A host that resizes us without changing
    /// `contentWidth` (a table row tracking a window wider than the
    /// column's max) still moves the column's centre — and with
    /// `.onSetNeedsDisplay` AppKit won't re-issue `draw(_:)` on a frame
    /// change on its own, so the cached bitmap would stay painted at the
    /// old centre.
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.size.width
        super.setFrameSize(newSize)
        if widthChanged {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    // MARK: - Draw

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let origin = contentOrigin
        #if DEBUG
        // Content typeset wider than its slot means the host measured at
        // a different width than it configured — surface it in
        // development instead of silently clipping.
        assert(
            contentWidth <= 0 || measuredWidth <= contentWidth + 0.5,
            "content typeset wider (\(measuredWidth)) than its column slot (\(contentWidth))"
        )
        #endif
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // Hard column boundary: nothing paints left / right of the slot.
        if contentWidth > 0 {
            ctx.clip(
                to: CGRect(x: origin.x, y: 0, width: contentWidth, height: bounds.height))
        }
        drawBackplate(in: ctx, origin: origin)
        drawSelectionBand(in: ctx, origin: origin)
        drawContent(in: ctx, origin: origin)
    }

    private func drawSelectionBand(in ctx: CGContext, origin: CGPoint) {
        guard let selection, let adapter = selectionAdapter else { return }
        let rects = adapter.rects(selection.start, selection.end)
        guard !rects.isEmpty else { return }
        let color: NSColor =
            (window?.isKeyWindow == true)
            ? .selectedTextBackgroundColor
            : .unemphasizedSelectedTextBackgroundColor
        ctx.setFillColor(color.cgColor)
        for rect in rects {
            // `integral` keeps the band's edges crisp on Retina.
            ctx.fill(rect.offsetBy(dx: origin.x, dy: origin.y).integral)
        }
    }

    // MARK: - Cursor + click

    override func resetCursorRects() {
        super.resetCursorRects()
        let origin = contentOrigin
        if selectionAdapter != nil {
            let rect =
                iBeamRect.map { $0.offsetBy(dx: origin.x, dy: origin.y) }
                ?? CGRect(
                    x: origin.x, y: origin.y,
                    width: measuredWidth, height: contentHeight)
            addCursorRect(rect, cursor: .iBeam)
        }
        for hit in interactiveHits {
            addCursorRect(
                hit.rect.offsetBy(dx: origin.x, dy: origin.y), cursor: .pointingHand)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard let action = hitAction(at: local) else {
            // Not one of our hot zones — let the event bubble up the
            // responder chain so an enclosing host (a table running its
            // own selection tracking loop) owns the gesture.
            super.mouseDown(with: event)
            return
        }
        switch action {
        case .openURL(let url):
            NSWorkspace.shared.open(url)
        case .copy(_, let text):
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        case .openUserBubbleSheet, .openImagePreview:
            // Host intents — presenting a sheet needs a controller, which
            // a dumb view doesn't have. A host that wants them observes
            // its own view subclass.
            break
        }
    }

    private func hitAction(at local: NSPoint) -> HitAction? {
        let origin = contentOrigin
        for hit in interactiveHits
        where hit.rect.offsetBy(dx: origin.x, dy: origin.y).contains(local) {
            return hit.action
        }
        return nil
    }
}
