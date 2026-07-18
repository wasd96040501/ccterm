import AppKit

/// Self-drawn outline cell. Reuses the `NativeTranscript2` cell drawing
/// path (`wantsLayer` + `.onSetNeedsDisplay` layer cache, `override
/// draw(_:)` painting a prepared `RowLayout`).
///
/// **Centering chokepoint.** The outline spans the full row width; the
/// centered 460–780 content column exists only here. `layoutOrigin` is
/// the single place the column offset is computed (via
/// `TranscriptOutlineMetrics`) — draw, cursor rects and hit tests all go
/// through it, and `draw(_:)` additionally clips the context to the
/// column slot, so a layout **cannot** paint outside the centered column
/// even if it misbehaves. Layouts stay column-agnostic: they only ever
/// see a `maxWidth` and a caller-supplied origin.
///
/// A dumb view: it renders whatever the controller's `viewFor` hands it
/// (`layout` / `layoutWidth` / `level` / `hasChevronSlot` / `padTop`),
/// opens link / copy hits, and forwards other clicks to the enclosing
/// outline so native disclosure keeps working.
final class OutlineBlockCellView: NSView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("OutlineBlockCell")

    /// Prepared layout for this row, set by the delegate's `viewFor`.
    var layout: RowLayout? {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    /// Width `layout` was typeset at — the clip slot's width.
    var layoutWidth: CGFloat = 0 {
        didSet { if layoutWidth != oldValue { needsDisplay = true } }
    }

    /// Outline level of this row's node; drives the per-level indent.
    var level: Int = 0 {
        didSet { if level != oldValue { needsDisplay = true } }
    }

    /// Header rows start their title after the native triangle's slot.
    var hasChevronSlot: Bool = false {
        didSet { if hasChevronSlot != oldValue { needsDisplay = true } }
    }

    /// Top padding contributed by the row; drives `layoutOrigin.y`.
    var padTop: CGFloat = 0 {
        didSet { if padTop != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Top-left of the layout in cell coordinates. The column position is
    /// computed in **row** coordinates from the row's full width (the
    /// row view spans the table), then converted by subtracting this
    /// cell's own frame offset — so the native outline-column inset on
    /// the cell frame cancels out instead of shifting the column.
    var layoutOrigin: CGPoint {
        let rowWidth = superview?.bounds.width ?? bounds.width
        let xInRow = TranscriptOutlineMetrics.contentX(
            forRowWidth: rowWidth, level: level, hasChevronSlot: hasChevronSlot)
        return CGPoint(x: max(0, xInRow - frame.origin.x), y: padTop)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let origin = layoutOrigin
        #if DEBUG
        // A layout typeset wider than its slot means some caller
        // bypassed `TranscriptOutlineMetrics.layoutWidth` — surface it
        // in development instead of silently clipping.
        assert(
            layoutWidth <= 0 || layout.measuredWidth <= layoutWidth + 0.5,
            "layout typeset wider (\(layout.measuredWidth)) than its column slot (\(layoutWidth))"
        )
        #endif
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // Hard column boundary: nothing paints left/right of the slot.
        if layoutWidth > 0 {
            ctx.clip(
                to: CGRect(x: origin.x, y: 0, width: layoutWidth, height: bounds.height))
        }
        // Opaque card chrome first (codeblock / tool-body), so any later
        // glyphs composite on top.
        layout.drawBackplate(in: ctx, origin: origin, dirtyRect: dirtyRect)
        layout.draw(in: ctx, origin: origin, hoveredAction: nil, dirtyRect: dirtyRect)
        // The codeblock copy glyph is drawn by the cell (not by
        // `RowLayout.draw`), matching the NativeTranscript2 cell — always
        // visible, no hover background in this cut.
        if case .codeBlock(let l) = layout, let chrome = l.copy {
            chrome.draw(in: ctx, origin: origin, hovered: false, flashing: false)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let layout else { return }
        let origin = layoutOrigin
        if layout.selectionAdapter != nil {
            let rect =
                layout.iBeamRect.map { $0.offsetBy(dx: origin.x, dy: origin.y) }
                ?? CGRect(
                    x: origin.x, y: origin.y,
                    width: layout.measuredWidth, height: layout.totalHeight)
            addCursorRect(rect, cursor: .iBeam)
        }
        for hit in layout.interactiveHits {
            addCursorRect(
                hit.rect.offsetBy(dx: origin.x, dy: origin.y), cursor: .pointingHand)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if let action = hitAction(at: local) {
            switch action {
            case .openURL(let url):
                NSWorkspace.shared.open(url)
            case .copy(_, let text):
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
            case .openUserBubbleSheet, .openImagePreview, .toggleFold:
                // These affordances aren't produced by the outline
                // transcript's layouts; nothing to do.
                break
            }
            return
        }
        // Not a layout hit — forward to the enclosing outline so native
        // row selection + double-click disclosure keep working.
        var view: NSView? = superview
        while let current = view {
            if let outline = current as? NSOutlineView {
                outline.mouseDown(with: event)
                return
            }
            view = current.superview
        }
    }

    private func hitAction(at local: NSPoint) -> HitAction? {
        guard let layout else { return nil }
        let origin = layoutOrigin
        for hit in layout.interactiveHits
        where hit.rect.offsetBy(dx: origin.x, dy: origin.y).contains(local) {
            return hit.action
        }
        return nil
    }
}
