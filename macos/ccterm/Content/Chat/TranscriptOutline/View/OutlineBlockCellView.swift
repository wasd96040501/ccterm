import AppKit

/// Self-drawn outline cell. Reuses the `NativeTranscript2` cell drawing
/// path (`wantsLayer` + `.onSetNeedsDisplay` layer cache, `override
/// draw(_:)` painting a prepared `RowLayout`) but **without** the
/// centering offset — the `TranscriptClipView` centers the whole outline
/// and the native indent expresses the hierarchy, so this cell only
/// insets by the block's standard horizontal padding (SPEC §6.4 /
/// decision 4).
///
/// A dumb view: it renders whatever `layout` / `padTop` the controller's
/// delegate hands it, opens link / copy hits, and forwards other clicks
/// to the enclosing outline so native selection + disclosure keep
/// working. Selection, search, hover, and the tool-group subview/chevron
/// machinery are out of scope for this cut.
final class OutlineBlockCellView: NSView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("OutlineBlockCell")

    /// Prepared layout for this row, set by the delegate's `viewFor`.
    var layout: RowLayout? {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
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

    /// No `cellOriginX` centering (the clip centers the outline); the
    /// left inset is just the block's standard horizontal padding, and
    /// the native indent has already shifted this cell's frame right.
    var layoutOrigin: CGPoint {
        CGPoint(x: BlockStyle.blockHorizontalPadding, y: padTop)
    }

    // Note: default clipping (clip to bounds) is intentionally kept — unlike
    // the monolithic `BlockCellView`, this cell hosts no overflowing subviews
    // / shadows, so clipping to bounds is a cheap safety net that keeps a
    // content width slightly over the estimated cell width from bleeding into
    // the centered column's gutter.
    override func draw(_ dirtyRect: NSRect) {
        guard let layout, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let origin = layoutOrigin
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
