import AppKit

/// Custom-drawn row cell. Holds a prepared `RowLayout`, draws it via
/// `override draw(_:)`.
///
/// Layer policy: `wantsLayer = true` + `.onSetNeedsDisplay`. The cached
/// layer bitmap is reused during scroll (zero `draw(_:)` calls), and AppKit
/// only re-issues `draw(_:)` after we mark `needsDisplay = true`.
///
/// ### Link interaction
///
/// `RowLayout.links` carries layout-local hot zones for `.link`-attributed
/// runs. The cell offsets them by `layoutOrigin` to get cell-local rects,
/// then:
/// - `mouseDown` opens the URL on a hit (and consumes the event).
/// - `resetCursorRects` registers a `pointingHand` cursor for each rect, so
///   the system handles cursor swapping during hover without us having to
///   install a tracking area.
///
/// ### Selection
///
/// `selectedRange` is set by `Transcript2Coordinator` (read from
/// `Transcript2SelectionCoordinator`). Length-0 means no selection. The
/// highlight paints **before** the glyphs in `draw(_:)`, matching
/// `NSTextView`'s order so anti-aliased glyphs blend correctly against
/// the system selection background.
///
/// Color: `selectedTextBackgroundColor` (key window) /
/// `unemphasizedSelectedTextBackgroundColor` (resigned). Both are dynamic
/// colors that auto-resolve to the cell's effective appearance and the
/// system Accent Color, so we never construct a custom selection color.
///
/// `mouseDown` not consumed by a link is forwarded directly to the
/// enclosing `NSTableView` so its tracking-loop override can run text
/// selection. Using `nextResponder?.mouseDown` would route through
/// `NSTableRowView`, whose default mouseDown forwarding behavior is not
/// guaranteed; the explicit walk is deterministic.
final class BlockCellView: NSView {
    var layout: RowLayout? {
        didSet {
            needsDisplay = true
            // Cursor rects are cached by AppKit per-view; layout changes
            // (resize, content swap) invalidate those caches so the new
            // link rects take effect on the next mouse motion.
            window?.invalidateCursorRects(for: self)
        }
    }

    /// Set by `viewFor` so selection-driven repaints (window-key flip,
    /// drag updates) can be addressed back to this cell. Stale on a
    /// recycled cell until the next `viewFor` runs — that's fine because
    /// recycle-driven repaint goes through the same `viewFor`.
    var blockId: UUID?

    /// Current text selection range for this cell's block. Length-0 =
    /// no selection. `didSet` triggers `needsDisplay` when the value
    /// actually changes; identical assignments are absorbed.
    var selectedRange: NSRange = NSRange(location: 0, length: 0) {
        didSet {
            if selectedRange != oldValue {
                needsDisplay = true
            }
        }
    }

    override var isFlipped: Bool { true }
    override var wantsDefaultClipping: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    private var layoutOrigin: CGPoint {
        CGPoint(
            x: BlockStyle.blockHorizontalPadding,
            y: BlockStyle.blockVerticalPadding)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let origin = layoutOrigin

        // Selection highlight: under glyphs, matching NSTextView ordering.
        // Only text-bearing rows have a TextLayout; image rows skip.
        if selectedRange.length > 0, let textLayout = layout.textLayout {
            paintSelection(in: ctx, layout: textLayout, origin: origin)
        }

        layout.draw(in: ctx, origin: origin)
    }

    /// `selectedTextBackgroundColor` resolves through `NSAppearance`, so
    /// light/dark and the system Accent Color come for free. The
    /// unemphasized variant is what `NSTextView` swaps to when its
    /// window resigns key — same gray, same source. Selection rects are
    /// pixel-aligned (`integral`) to keep the bg edges crisp on Retina
    /// at non-1× scale.
    private func paintSelection(in ctx: CGContext,
                                layout textLayout: TextLayout,
                                origin: CGPoint) {
        let rects = textLayout.selectionRects(for: selectedRange)
        guard !rects.isEmpty else { return }
        let color: NSColor = (window?.isKeyWindow == true)
            ? .selectedTextBackgroundColor
            : .unemphasizedSelectedTextBackgroundColor
        ctx.setFillColor(color.cgColor)
        for rect in rects {
            ctx.fill(rect.offsetBy(dx: origin.x, dy: origin.y).integral)
        }
    }

    // MARK: - Link interaction

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let layout else { return }
        // I-beam over the entire cell for text-bearing blocks — matches
        // `NSTextView`'s behavior of showing I-beam over its full frame
        // (including any internal padding). Order matters: when cursor
        // rects overlap, the most-recently-added wins, so the link
        // pointing-hand registered below takes priority inside link
        // hot zones. Image rows skip — they get the default arrow.
        if layout.textLayout != nil {
            addCursorRect(bounds, cursor: .iBeam)
        }
        let origin = layoutOrigin
        for hit in layout.links {
            addCursorRect(hit.rect.offsetBy(dx: origin.x, dy: origin.y),
                          cursor: .pointingHand)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let url = linkURL(at: event) {
            NSWorkspace.shared.open(url)
            return
        }
        // Forward to the enclosing table so its tracking loop owns the
        // gesture (text-selection drag). Walk the superview chain rather
        // than relying on `nextResponder` — `NSTableRowView`'s default
        // mouseDown behavior isn't documented as forwarding.
        var v: NSView? = superview
        while let cur = v {
            if let table = cur as? NSTableView {
                table.mouseDown(with: event)
                return
            }
            v = cur.superview
        }
    }

    private func linkURL(at event: NSEvent) -> URL? {
        guard let layout else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        let origin = layoutOrigin
        for hit in layout.links {
            if hit.rect.offsetBy(dx: origin.x, dy: origin.y).contains(local) {
                return hit.url
            }
        }
        return nil
    }
}
