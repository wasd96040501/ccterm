import AppKit

/// Custom-drawn row cell. Holds a prepared `RowLayout`, draws it via
/// `override draw(_:)`.
///
/// Layer policy: `wantsLayer = true` + `.onSetNeedsDisplay`. The cached
/// layer bitmap is reused during scroll (zero `draw(_:)` calls), and AppKit
/// only re-issues `draw(_:)` after we mark `needsDisplay = true`.
///
/// ### Cursor + click dispatch
///
/// The cell is layout-agnostic for both. `RowLayout` exposes:
/// - `iBeamRect`: where the I-beam should show on hover (`nil` = full
///   cell `bounds`, the default for full-width text blocks; user-bubble
///   confines this to its right-aligned `bubbleRect` so the empty left
///   gutter keeps the default arrow).
/// - `interactiveHits`: list of `(rect, HitAction)` pairs covering URL
///   links, the user-bubble chevron, and the code-block copy button.
///
/// `resetCursorRects` registers I-beam over `iBeamRect` and pointing-
/// hand over each `interactiveHits` rect. AppKit handles hover cursor
/// swap automatically — no tracking area needed.
///
/// `mouseDown` walks the same `interactiveHits` list once, switches on
/// the matched `HitAction`, and falls through to selection-drag
/// forwarding when no hit is found. Adding a new in-cell control means
/// emitting another `InteractiveHit` from the relevant layout and
/// adding one switch arm here — no new `if case .xxx = layout` chains.
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

    /// Timestamp of the most recent copy click on this cell's code
    /// block, or `nil` when the button should display its idle
    /// (`doc.on.doc`) glyph. Set on click; cleared 1.5s later by a
    /// task that compares the timestamp before clearing (so a quick
    /// second click doesn't get its checkmark cut short by the first
    /// click's pending clear). Reset to `nil` on every `viewFor`
    /// reuse — the feedback is opportunistic, missing it on a
    /// scroll-recycled cell is fine.
    private var copiedAt: Date?

    /// `HitAction` of the `InteractiveHit` currently under the cursor,
    /// or `nil` when no hit is hovered. Drives per-region hover
    /// affordance inside layouts that opt in (today: toolGroup header
    /// hover brightens title + chevron).
    ///
    /// Updated by `mouseMoved` whenever the tracked location enters or
    /// leaves a hit rect; transitions trigger a single
    /// `needsDisplay = true`. Cleared on every `viewFor` reuse so a
    /// recycled cell never inherits another row's hover state.
    private var hoveredAction: HitAction?

    /// Tracking area covering the whole cell — `inVisibleRect` keeps
    /// it sized correctly through scroll without manual reseating.
    private var trackingArea: NSTrackingArea?

    /// Public reset hook for `viewFor` so a recycled cell never shows
    /// a stale checkmark on a different block.
    func resetCopiedFeedback() {
        if copiedAt != nil {
            copiedAt = nil
            needsDisplay = true
        }
    }

    /// Public reset hook for `viewFor` so a recycled cell never
    /// inherits the previous block's hover affordance.
    func resetHover() {
        if hoveredAction != nil {
            hoveredAction = nil
            needsDisplay = true
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

        // Backplate: opaque chrome that must paint *before* the
        // selection band so the highlight composites on top of (not
        // under) the card. No-op for everything except codeblock,
        // which has an opaque editor-canvas fill.
        layout.drawBackplate(in: ctx, origin: origin)

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

        layout.draw(in: ctx, origin: origin, hoveredAction: hoveredAction)

        // Code-block copy glyph — layout owns the visual recipe
        // (symbol, tint, size); the cell only owns the trigger and
        // hands its transient `copiedAt` flag through as `checked`.
        if case .codeBlock(let l) = layout {
            l.drawCopyGlyph(in: ctx, origin: origin, checked: copiedAt != nil)
        }
    }

    // MARK: - Hover tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea {
            removeTrackingArea(area)
        }
        // `.inVisibleRect` ⇒ AppKit owns the rect, no manual re-seat
        // on scroll. `.activeInKeyWindow` matches the
        // `.selectedTextBackgroundColor` switch behaviour so hover
        // state and selection both go quiet when the window resigns
        // key. `.mouseMoved` is required for transient hits that the
        // pointer didn't enter through the cell's outer boundary
        // (e.g. moved sideways within the cell across two adjacent
        // headers).
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited,
                      .mouseMoved,
                      .activeInKeyWindow,
                      .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredAction != nil {
            hoveredAction = nil
            needsDisplay = true
        }
    }

    private func updateHover(at local: NSPoint) {
        guard let layout else { return }
        let origin = layoutOrigin
        var newHover: HitAction?
        for hit in layout.interactiveHits {
            if hit.rect.offsetBy(dx: origin.x, dy: origin.y).contains(local) {
                newHover = hit.action
                break
            }
        }
        if newHover != hoveredAction {
            hoveredAction = newHover
            needsDisplay = true
        }
    }

    // MARK: - Link interaction

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let layout else { return }
        let origin = layoutOrigin
        // I-beam: over `iBeamRect` if the layout confines it
        // (user bubble), else the whole cell `bounds` to match
        // `NSTextView`'s "I-beam over full frame" behavior. Order
        // matters: when cursor rects overlap, the most-recently-
        // added wins, so pointing-hand rects registered below take
        // priority over the I-beam in their hot zones. Non-
        // selectable rows (image, thematic break) skip — they get
        // the default arrow.
        if layout.selectionAdapter != nil {
            let rect = layout.iBeamRect.map {
                $0.offsetBy(dx: origin.x, dy: origin.y)
            } ?? bounds
            addCursorRect(rect, cursor: .iBeam)
        }
        for hit in layout.interactiveHits {
            addCursorRect(hit.rect.offsetBy(dx: origin.x, dy: origin.y),
                          cursor: .pointingHand)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let action = hitAction(at: event) {
            switch action {
            case .openURL(let url):
                NSWorkspace.shared.open(url)
            case .openUserBubbleSheet:
                // The only well-defined exit point from AppKit-internal
                // interactions to SwiftUI, since `.sheet(item:)` lives
                // on the SwiftUI side. Selection-drag continues to stay
                // inside `Transcript2SelectionCoordinator`.
                if let id = blockId {
                    coordinator?.requestUserBubbleSheet(id: id)
                }
            case .copyText(let text):
                copyToPasteboard(text)
            case .toggleFold(let id):
                coordinator?.toggleFold(id: id)
            }
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

    private func hitAction(at event: NSEvent) -> HitAction? {
        guard let layout else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        let origin = layoutOrigin
        for hit in layout.interactiveHits {
            if hit.rect.offsetBy(dx: origin.x, dy: origin.y).contains(local) {
                return hit.action
            }
        }
        return nil
    }

    private func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        // Visual feedback: swap idle → checkmark, schedule a swap back
        // 1.5s later. Stamp identity prevents a quick second click's
        // checkmark from being cut short by the first click's
        // pending clear.
        let stamp = Date()
        copiedAt = stamp
        needsDisplay = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, self.copiedAt == stamp else { return }
            self.copiedAt = nil
            self.needsDisplay = true
        }
    }
}
