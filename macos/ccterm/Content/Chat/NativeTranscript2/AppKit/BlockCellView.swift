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
///
/// ### Adornments (chevrons + entry subviews)
///
/// Some layouts (today only `toolGroup`) need AppKit-side adornments
/// on top of the cell's CGContext draw — spinning chevron glyphs and
/// per-band layer-backed subviews that can slide independently of the
/// row-height transition. The cell consumes those through `RowLayout.subviewPlan`
/// (see `BlockCellView+SubviewPlan.swift`). The cell stays
/// layout-agnostic — the plan is a struct of values + closures, same
/// recipe as `SelectionAdapter`.
final class BlockCellView: NSView {
    var layout: RowLayout? {
        didSet {
            needsDisplay = true
            // Cursor rects are cached by AppKit per-view; layout changes
            // (resize, content swap) invalidate those caches so the new
            // link rects take effect on the next mouse motion.
            window?.invalidateCursorRects(for: self)
            // Re-evaluate hover against the current cached mouse position.
            // Without this, a fold-toggle click that triggers `reloadData`
            // (and a new `layout` here) leaves the cursor over the same
            // hit zone but `hoveredAction = nil` until the next
            // `mouseMoved` — the title brightening + chevron alpha visibly
            // drop until the user wiggles the mouse. Re-evaluating from
            // the cached event-stream position re-establishes hover as
            // soon as the new layout's hits are known. The re-evaluation
            // may set `hoveredAction`, which itself triggers a plan sync;
            // the explicit call after covers the no-hover-change case.
            reevaluateHoverFromCachedMouseLocation()
            syncSubviewPlan()
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
    var padTop: CGFloat = 0 {
        didSet {
            if padTop != oldValue {
                syncSubviewPlan()
            }
        }
    }

    /// Current selection for this cell's block. `nil` = no selection.
    /// `didSet` triggers `needsDisplay` when the value actually changes;
    /// identical assignments are absorbed.
    var selection: SelectionRange? {
        didSet {
            if selection != oldValue {
                needsDisplay = true
                // Plan carries the latest selection rects into every
                // entry subview's draw closure, so a selection change
                // routes through the same reconcile path as a layout
                // change or hover change.
                syncSubviewPlan()
            }
        }
    }

    /// In-transcript search highlights overlaying this cell. `nil` /
    /// empty = no overlay. Each entry carries a `SelectionRange` (in
    /// the layout's own opaque coords — same shape selection uses) and
    /// an `isCurrent` flag that switches the fill from inactive yellow
    /// to active orange-yellow.
    var searchHighlights: [SearchHighlightSpec]? {
        didSet {
            if searchHighlights != oldValue {
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
    /// `needsDisplay = true` plus a plan resync (which rebuilds chevron
    /// hover styles and entry subview hover state in one shot).
    var hoveredAction: HitAction? {
        didSet {
            if hoveredAction != oldValue {
                needsDisplay = true
                syncSubviewPlan()
            }
        }
    }

    /// Tracking area covering the whole cell — `inVisibleRect` keeps
    /// it sized correctly through scroll without manual reseating.
    private var trackingArea: NSTrackingArea?

    // MARK: - Gutter state
    //
    // Gutters are cell-level decorations (copy button in the row
    // margin, etc.). They are not part of the layout pipeline — see
    // `GutterSpec` and `BlockCellView+Gutter.swift`. Stored here
    // because Swift extensions cannot add stored properties.

    /// Per-block gutter specs, set by `viewFor`. `didSet` invalidates
    /// the cursor rect cache so the new gutters' pointing-hand zones
    /// take effect on the next mouse motion, and forces a redraw so
    /// reused cells repaint their gutters at the new geometry.
    var gutters: [GutterSpec] = [] {
        didSet {
            if gutters != oldValue {
                needsDisplay = true
                window?.invalidateCursorRects(for: self)
            }
        }
    }

    /// `true` while the mouse is inside the cell's bounds, regardless
    /// of whether a specific hit is under it. Drives gutter visibility:
    /// gutters fade in only when the row is hovered, matching the
    /// Slack / Linear / Cursor convention of "row-margin chrome is
    /// hidden until the row is the focus of attention". Toggled by
    /// `mouseEntered` / `mouseExited`.
    var cellHovered: Bool = false {
        didSet {
            if cellHovered != oldValue { needsDisplay = true }
        }
    }

    /// Gutter id currently under the cursor, or `nil`. Drives the
    /// rounded hover background + the glyph's hover tint. Sibling to
    /// `hoveredAction` — gutter hover and layout hover are tracked
    /// separately because a gutter click is dispatched cell-side, not
    /// through `HitAction`.
    var hoveredGutterId: UUID? {
        didSet {
            if hoveredGutterId != oldValue { needsDisplay = true }
        }
    }

    /// Per-gutter checkmark-feedback timestamps. Set on click, cleared
    /// after `BlockStyle.gutterCopiedFeedbackSeconds`. Same identity-
    /// stamped clear pattern as `copiedAt`: a quick second click
    /// stamps a new value, the first click's pending clear sees the
    /// mismatch and bails so the second flash isn't cut short.
    var gutterCopiedAt: [UUID: Date] = [:]

    // MARK: - Subview-plan state
    //
    // Stored properties live in the main class declaration because
    // Swift extensions can't add stored properties to a class. The
    // logic that consumes them lives in `BlockCellView+SubviewPlan.swift`.

    /// Per-foldId chevron sublayers. Created lazily on first plan
    /// that surfaces a chevron with the id; reused across re-layouts
    /// so rotation animations span the underlying `reloadData(forRowIndexes:)`.
    var chevronLayers: [UUID: CAShapeLayer] = [:]

    /// Per-entry layer-backed subviews. Cell's main bitmap paints the
    /// group header only; child entries live in these subviews so
    /// `view.animator().frame` can slide each one when an upstream
    /// sibling expands/collapses.
    var entryViews: [UUID: ToolGroupEntryView] = [:]

    /// Per-headerId shimmer layer pairs (host + mask). Created on the
    /// first plan that surfaces a shimmer for a `.running` header;
    /// reused across re-layouts so the sweeping `locations` animation
    /// keeps cycling past `reloadData(forRowIndexes:)` rather than
    /// restarting (which would visibly snap the highlight stripe back
    /// to its origin every status flip / hover transition).
    var shimmerLayers: [UUID: ShimmerLayerSet] = [:]

    /// Per-index dot sublayers for the trailing "running" pill. Keyed
    /// by `index` (0/1/2) so the layer survives `reloadData` /
    /// resize re-layouts and the breathing opacity animation keeps
    /// cycling without phase reset. Cleared when the plan emits no
    /// `loadingDots` (pill gone / row recycled to another kind).
    var loadingDotLayers: [Int: CAShapeLayer] = [:]

    /// Set by `beginFoldTransition` just before the coordinator's
    /// `reloadData`. Tells the upcoming `syncSubviewPlan()` to route
    /// entry-frame updates through `view.animator()` so each entry
    /// slides over the fold-animation duration. Auto-reset once
    /// consumed — subsequent syncs (resize, hover, selection) snap.
    var pendingFoldTransition: Bool = false

    /// Public reset hook for `viewFor` so a recycled cell never shows
    /// a stale checkmark on a different block. Clears both the
    /// codeblock in-header copy flash and every gutter's copy flash.
    func resetCopiedFeedback() {
        var changed = false
        if copiedAt != nil {
            copiedAt = nil
            changed = true
        }
        if !gutterCopiedAt.isEmpty {
            gutterCopiedAt.removeAll()
            changed = true
        }
        if changed {
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

    /// Resize-driven re-centering. NSTableView resizes our frame to track
    /// the row's width on every tile pass. `layoutOrigin.x` is derived
    /// from `bounds.width` (`BlockStyle.cellOriginX`), so a width change
    /// shifts where the layout's draw origin should land — but with
    /// `.onSetNeedsDisplay` AppKit doesn't auto-mark the layer dirty,
    /// and entry subviews keep their old `subviewPlan`-built frames.
    /// Result without this hook: in-band resizes (raw width changes that
    /// don't move the clamped `layoutWidth`) leave already-cached cells
    /// painted at the old centred origin while new scroll-in cells use
    /// the new origin — visible as a horizontal tear.
    /// `Coordinator.tableFrameDidChange` short-circuits in that band on
    /// purpose (no Core Text relayout needed), so the redraw obligation
    /// belongs here.
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.size.width
        super.setFrameSize(newSize)
        if widthChanged {
            needsDisplay = true
            syncSubviewPlan()
        }
    }

    /// Backing-scale change (cell joined a window, window dragged
    /// across displays with different `backingScaleFactor`). AppKit
    /// auto-updates the *host* layer's `contentsScale` and re-issues
    /// `draw(_:)`, so the cell-bitmap title rasterises at the new
    /// pixel density on its own. But manually-managed sublayers
    /// (`shimmerLayers`, `chevronLayers`) don't auto-inherit — their
    /// `contentsScale` stays at whatever value we wrote at creation,
    /// which would leave overlay glyphs rasterised at the old scale
    /// (visibly soft on a higher-DPI display).
    ///
    /// Push the new scale into every sublayer here, and invalidate
    /// each shimmer layer's `imageKey` so the next reconcile (forced
    /// via `syncSubviewPlan` below) re-rasters the glyph bitmap at
    /// the new pixel density. Chevron layers don't have backing
    /// images — they're vector `CAShapeLayer`s — so updating
    /// `contentsScale` is enough; CoreAnimation re-strokes the path
    /// at the new scale on the next composite.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale =
            window?.backingScaleFactor
            ?? self.layer?.contentsScale
            ?? 2
        for (_, set) in shimmerLayers {
            set.text.contentsScale = scale
            set.mask.contentsScale = scale
            set.imageKey = nil
        }
        for (_, layer) in chevronLayers {
            layer.contentsScale = scale
        }
        for (_, layer) in loadingDotLayers {
            layer.contentsScale = scale
        }
        syncSubviewPlan()
    }

    /// Layout-local origin where the row's `RowLayout` paints. The
    /// cell's frame spans the row's full width (NSTableView's
    /// view-based contract); we shift content here so it lands at the
    /// centered position. `cellOriginX` is the same value
    /// `Transcript2SelectionCoordinator` uses to convert document
    /// points into layout-local coords, so cell-side draw / hit / sel
    /// rects all stay aligned.
    var layoutOrigin: CGPoint {
        CGPoint(
            x: BlockStyle.cellOriginX(forRowWidth: bounds.width)
                + BlockStyle.blockHorizontalPadding,
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
        //
        // For layouts that hand selection-bearing regions off to entry
        // subviews (today: toolGroup), the cell-bitmap copy is harmless:
        // the subview's frame necessarily covers every selection rect
        // the layout emits, so the subview-composited bitmap (which
        // re-paints the same selection rects in view-local coords) hides
        // this one. Letting both paths coexist keeps the cell ignorant
        // of whether a given layout uses subviews.
        if let selection, let adapter = layout.selectionAdapter {
            let rects = adapter.rects(selection.start, selection.end)
            if !rects.isEmpty {
                let color: NSColor =
                    (window?.isKeyWindow == true)
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

        // Search highlights composite *over* the selection band so a
        // search hit overlapping the selection still reads as yellow
        // (the search task is the active foreground task). Glyphs
        // then paint over both — same NSTextView ordering.
        if let hits = searchHighlights, !hits.isEmpty,
            let adapter = layout.selectionAdapter
        {
            let isKey = window?.isKeyWindow == true
            for hit in hits {
                let rects = adapter.rects(hit.range.start, hit.range.end)
                if rects.isEmpty { continue }
                let color: NSColor =
                    hit.isCurrent
                    ? Self.searchActiveFillColor(isKey: isKey)
                    : Self.searchInactiveFillColor(isKey: isKey)
                ctx.setFillColor(color.cgColor)
                for rect in rects {
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

        // Gutters — cell-margin copy affordances, painted last so a
        // hover background never sits under content. Self-drawn (no
        // CALayer) because the only animation is a `needsDisplay`-
        // driven swap between idle / hover / copied. See
        // `BlockCellView+Gutter.swift`.
        drawGutters(in: ctx)
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
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .activeInKeyWindow,
                .inVisibleRect,
            ],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        updateHover(at: p)
        updateGutterHover(at: p)
    }

    override func mouseEntered(with event: NSEvent) {
        cellHovered = true
        let p = convert(event.locationInWindow, from: nil)
        updateHover(at: p)
        updateGutterHover(at: p)
    }

    override func mouseExited(with event: NSEvent) {
        cellHovered = false
        if hoveredAction != nil {
            hoveredAction = nil
        }
        if hoveredGutterId != nil {
            hoveredGutterId = nil
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
        }
    }

    /// Re-evaluate hover state from the current cached mouse location.
    /// Called when `layout` changes so a content swap that keeps the
    /// cursor over the same hit zone preserves the hover affordance
    /// without waiting for the next `mouseMoved` event.
    private func reevaluateHoverFromCachedMouseLocation() {
        guard let window else {
            if hoveredAction != nil {
                hoveredAction = nil
            }
            return
        }
        // `mouseLocationOutsideOfEventStream` is the AppKit-cached
        // pointer position in window coordinates — available even when
        // we aren't in a mouse event handler (we're inside a `didSet`).
        let windowPoint = window.mouseLocationOutsideOfEventStream
        let local = convert(windowPoint, from: nil)
        guard bounds.contains(local) else {
            if hoveredAction != nil {
                hoveredAction = nil
            }
            return
        }
        updateHover(at: local)
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
            let rect =
                layout.iBeamRect.map {
                    $0.offsetBy(dx: origin.x, dy: origin.y)
                } ?? bounds
            addCursorRect(rect, cursor: .iBeam)
        }
        for hit in layout.interactiveHits {
            addCursorRect(
                hit.rect.offsetBy(dx: origin.x, dy: origin.y),
                cursor: .pointingHand)
        }
        // Gutter pointing-hand rects — registered last so they win
        // overlap with the I-beam over the layout content area.
        // `visibleGutterRect` honors the "clip on narrow window"
        // contract so a non-visible gutter doesn't register a stray
        // cursor swap.
        for spec in gutters {
            if let r = visibleGutterRect(for: spec) {
                addCursorRect(r, cursor: .pointingHand)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Gutter hits are tested first so a gutter click never falls
        // through to selection drag (the table-forward path below).
        // Gutters dispatch entirely cell-side — they don't go through
        // `HitAction`, which is reserved for layout-internal hits.
        let local = convert(event.locationInWindow, from: nil)
        if let spec = gutterAt(local) {
            handleGutterClick(spec)
            return
        }
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

    // MARK: - Search highlight palette

    /// Inactive (non-current) hit fill. Pale yellow at low alpha so
    /// it reads as "found here, not focused", clearly distinct from
    /// the selection band's blue-ish system tint. Slightly weaker
    /// when the window has resigned key — matches selection's
    /// emphasized/unemphasized split so an inactive transcript
    /// doesn't shout for attention.
    nonisolated static func searchInactiveFillColor(isKey: Bool) -> NSColor {
        let alpha: CGFloat = isKey ? 0.42 : 0.28
        return NSColor.systemYellow.withAlphaComponent(alpha)
    }

    /// Active (current-cursor) hit fill. Same yellow family, deeper
    /// alpha + a slight orange shift so the active marker reads as
    /// the focus among a cloud of inactive hits without changing
    /// hue tier (so the eye still groups every hit as "the search
    /// set").
    nonisolated static func searchActiveFillColor(isKey: Bool) -> NSColor {
        // `systemOrange.withAlphaComponent` lands on the same warm
        // yellow ramp as `systemYellow` at deeper alpha — the macOS
        // accent uses the same hue space for find-bar highlights in
        // Safari / Mail.
        let alpha: CGFloat = isKey ? 0.78 : 0.55
        return NSColor.systemOrange.withAlphaComponent(alpha)
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
