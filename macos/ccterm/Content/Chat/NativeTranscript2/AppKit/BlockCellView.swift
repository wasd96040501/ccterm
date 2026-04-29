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

    /// Set by `viewFor`. Used by mouseDown when a hit lands on a control
    /// belonging to the cell's layout (currently: user bubble chevron).
    /// Selection drag still walks to the enclosing `NSTableView` because
    /// AppKit's tracking loop owns that gesture — only cell-internal
    /// controls go through this reference.
    weak var coordinator: Transcript2Coordinator?

    /// Top padding contributed by the block's row (per-kind via
    /// `BlockStyle.blockPadding(for:)`). Drives `layoutOrigin.y` and
    /// selection rect offsetting. Set by `viewFor` alongside `layout`.
    var padTop: CGFloat = 0

    /// Current selection for this cell's block. `nil` = no selection.
    /// `didSet` triggers `needsDisplay` when the value actually changes;
    /// identical assignments are absorbed.
    var selection: SelectionRange? {
        didSet {
            if selection != oldValue {
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
            y: padTop)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let origin = layoutOrigin

        // Selection highlight: under glyphs, matching NSTextView ordering.
        // The adapter projects (start, end) → layout-local rects; what
        // those rects mean (text glyph band / cell rectangle / 1×1 inner
        // band) is fully encapsulated inside the layout's adapter.
        if let selection, let adapter = layout.selectionAdapter {
            let rects = adapter.rects(selection.start, selection.end)
            if !rects.isEmpty {
                let color: NSColor = (window?.isKeyWindow == true)
                    ? .selectedTextBackgroundColor
                    : .unemphasizedSelectedTextBackgroundColor
                ctx.setFillColor(color.cgColor)
                for rect in rects {
                    // `integral` keeps the bg edges crisp on Retina at
                    // non-1× scale.
                    ctx.fill(rect.offsetBy(dx: origin.x, dy: origin.y).integral)
                }
            }
        }

        layout.draw(in: ctx, origin: origin)
    }

    // MARK: - Link interaction

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let layout else { return }
        // I-beam over the entire cell for any selectable block — matches
        // `NSTextView`'s behavior of showing I-beam over its full frame
        // (including any internal padding). Order matters: when cursor
        // rects overlap, the most-recently-added wins, so pointing-hand
        // rects registered below take priority over the I-beam in their
        // hot zones. Non-selectable rows (image) skip — they get the
        // default arrow.
        if layout.selectionAdapter != nil {
            addCursorRect(bounds, cursor: .iBeam)
        }
        let origin = layoutOrigin
        for hit in layout.links {
            addCursorRect(hit.rect.offsetBy(dx: origin.x, dy: origin.y),
                          cursor: .pointingHand)
        }
        if case .userBubble(let l) = layout, let chev = l.chevronHitRect {
            addCursorRect(chev.offsetBy(dx: origin.x, dy: origin.y),
                          cursor: .pointingHand)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let url = linkURL(at: event) {
            NSWorkspace.shared.open(url)
            return
        }
        // Cell-internal control: user bubble chevron. Goes through the
        // coordinator's sheet-request channel — the only well-defined
        // exit point from AppKit-internal interactions to SwiftUI, since
        // `.sheet(item:)` lives on the SwiftUI side. Selection-drag
        // continues to stay inside `Transcript2SelectionCoordinator`.
        if let id = blockId, hitChevron(at: event) {
            coordinator?.requestUserBubbleSheet(id: id)
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

    private func hitChevron(at event: NSEvent) -> Bool {
        guard case .userBubble(let l)? = layout,
              let hit = l.chevronHitRect
        else { return false }
        let local = convert(event.locationInWindow, from: nil)
        let origin = layoutOrigin
        return hit.offsetBy(dx: origin.x, dy: origin.y).contains(local)
    }
}
