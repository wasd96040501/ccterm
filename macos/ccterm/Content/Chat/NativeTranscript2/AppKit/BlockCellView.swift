import AppKit
import QuartzCore

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
/// ### Chevron animation
///
/// Fold-header chevrons live as `CAShapeLayer` sublayers (one per
/// foldId surfaced by the layout), not as CGContext strokes. This is
/// the same recipe the old `GroupSideCar` used and is far simpler than
/// a hand-rolled per-frame redraw loop: `beginChevronAnimation`
/// captures the layer's presentation-tree rotation, snaps the model
/// value inside a disabled-actions transaction, then adds an explicit
/// `CABasicAnimation` on `transform.rotation.z`. CALayer does the
/// frame-by-frame interpolation for free. The full content swap on
/// fold (new headers / body cards appearing) is animated through a
/// single `CATransition.fade` on the cell layer.
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
            // soon as the new layout's hits are known.
            reevaluateHoverFromCachedMouseLocation()
            syncChevronSublayers()
            syncEntrySubviews()
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
                syncChevronSublayers()
                syncEntrySubviews()
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
                // Diff selection lives inside per-entry subviews
                // (paint sandwich is body-local); push the new
                // layout-local rect list out so each entry can
                // refresh its slice.
                pushSelectionToEntrySubviews()
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
    /// `needsDisplay = true` plus a chevron-style refresh.
    private var hoveredAction: HitAction? {
        didSet {
            if hoveredAction != oldValue {
                needsDisplay = true
                updateChevronHoverStyles()
                updateEntrySubviewHoverStates()
            }
        }
    }

    /// Tracking area covering the whole cell — `inVisibleRect` keeps
    /// it sized correctly through scroll without manual reseating.
    private var trackingArea: NSTrackingArea?

    /// Per-foldId chevron sublayers. Created lazily on first layout
    /// that surfaces a header for the id; reused across re-layouts of
    /// the same row (so rotation animations span the underlying
    /// `reloadData(forRowIndexes:)` that fold toggle triggers).
    private var chevronLayers: [UUID: CAShapeLayer] = [:]

    /// Per-child layer-backed subviews holding each `ToolGroupLayout.Entry`'s
    /// rendered content (child header + optional body). Cell's main
    /// bitmap paints the group header only; child entries live in
    /// these subviews so AppKit's `animator()` proxy can slide each
    /// subview's frame when an upstream sibling expands/collapses.
    /// Inside one row, the row-height transition alone fades — only
    /// per-subview frame animation produces the slide the user sees.
    private var entryViews: [UUID: ToolGroupEntryView] = [:]

    /// Set by `Transcript2Coordinator.toggleFold` just before
    /// `reloadData` (alongside `beginChevronAnimation` /
    /// `beginContentCrossFade`). Tells the upcoming
    /// `syncEntrySubviews()` to push entry-frame updates through
    /// `view.animator()` so the entries below the toggled one slide
    /// over the fold-animation duration. Auto-reset once consumed —
    /// other layout swaps (resize, scroll recycle) snap frames as
    /// usual.
    private var pendingEntryAnimation: Bool = false

    /// Public reset hook for `viewFor` so a recycled cell never shows
    /// a stale checkmark on a different block.
    func resetCopiedFeedback() {
        if copiedAt != nil {
            copiedAt = nil
            needsDisplay = true
        }
    }

    /// Animate this row's chevron rotation in response to a fold
    /// toggle. Called by `Transcript2Coordinator.toggleFold` *before*
    /// it reloads the row so the layer captures its current
    /// presentation-tree rotation as the animation's `fromValue`. The
    /// `reloadData(forRowIndexes:)` that follows reuses the same cell
    /// instance for the same row, so the rotation animation is
    /// preserved across the `layout` swap.
    ///
    /// Recipe lifted from `GroupSideCar.sync`: snap the model value
    /// inside a disabled-actions transaction, then add the explicit
    /// `CABasicAnimation` outside it (an implicit-action chain would
    /// be killed by `setDisableActions(true)`).
    func beginChevronAnimation(foldId: UUID, toExpanded: Bool) {
        guard let layer = chevronLayers[foldId] else { return }
        let presValue = layer.presentation()?
            .value(forKeyPath: "transform.rotation.z") as? CGFloat
        let modelValue = (layer.value(forKeyPath: "transform.rotation.z") as? CGFloat) ?? 0
        let fromAngle = presValue ?? modelValue
        let toAngle: CGFloat = toExpanded ? .pi / 2 : 0

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(toAngle, forKeyPath: "transform.rotation.z")
        CATransaction.commit()

        let anim = CABasicAnimation(keyPath: "transform.rotation.z")
        anim.duration = BlockStyle.foldAnimationDuration
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        anim.fromValue = fromAngle
        anim.toValue = toAngle
        layer.add(anim, forKey: "rotate")
    }

    /// Cross-fade the cell's CGContext-drawn contents over the same
    /// duration as the chevron rotation, so the new headers / body
    /// cards appear with a soft fade instead of a pop. `CATransition`
    /// on the host layer is the AppKit-blessed way to do this —
    /// QuartzCore handles the bitmap diff between the layer's old
    /// snapshot and its post-redraw state. Chevron sublayers run
    /// their own `CABasicAnimation` independently.
    func beginContentCrossFade() {
        guard let hostLayer = self.layer else { return }
        let transition = CATransition()
        transition.type = .fade
        transition.duration = BlockStyle.foldAnimationDuration
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        hostLayer.add(transition, forKey: "contentFade")
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
        //
        // toolGroup is the one exception: its selection lands inside
        // expanded body cards that live in per-entry subviews, so the
        // sandwich (backplate → selection → glyphs) has to happen
        // inside the subview's `draw(_:)` — painting selection here
        // would land behind the subview, not under the body glyphs.
        if !layout.isToolGroup, let selection, let adapter = layout.selectionAdapter {
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

    // MARK: - Chevron sublayers

    /// Reconcile `chevronLayers` with the current layout's surfaced
    /// chevron headers. For each header, ensure a `CAShapeLayer`
    /// exists, position it at the chevron centre in cell-local
    /// coords, snap its model rotation to match the layout's
    /// `chevronExpanded` flag, and apply hover-aware colour / opacity.
    /// Layers for ids that vanished from the layout (collapsed group
    /// hides its children) are removed.
    ///
    /// **Position-animation policy.** First-time placement of a
    /// fresh layer happens inside `setDisableActions(true)` so the
    /// initial `position` set doesn't lerp from `(0, 0)`. Repositions
    /// of an existing layer let the *surrounding* CATransaction
    /// decide: during a fold transition,
    /// `Coordinator.toggleFold`'s `NSAnimationContext.runAnimationGroup`
    /// is active → chevron `position` slides over `foldAnimationDuration`,
    /// matching the entry's `animator().frame` slide. Outside of
    /// that — e.g. window resize, which wraps in
    /// `CATransaction.setDisableActions(true)` — actions stay
    /// disabled and chevron snaps. (`makeChevronShapeLayer` NSNull-s
    /// `bounds` / `frame` / `path` / colour so only `position`
    /// participates in the implicit animation channel.)
    private func syncChevronSublayers() {
        guard let hostLayer = self.layer else { return }
        let descs: [ChevronDescriptor]
        if case .toolGroup(let l) = layout {
            descs = chevronDescriptors(in: l)
        } else {
            descs = []
        }
        var seen = Set<UUID>()
        let chevronSize = BlockStyle.toolHeaderChevronSize

        for desc in descs {
            seen.insert(desc.foldId)
            let isNew = chevronLayers[desc.foldId] == nil
            let layer = chevronLayers[desc.foldId] ?? makeChevronShapeLayer()
            let frame = CGRect(x: desc.center.x - chevronSize / 2,
                               y: desc.center.y - chevronSize / 2,
                               width: chevronSize, height: chevronSize)

            if isNew {
                chevronLayers[desc.foldId] = layer
                hostLayer.addSublayer(layer)
                // Initial placement: snap (otherwise the fresh
                // layer's `(0, 0) → desc.center` move would lerp
                // under any active CATransaction).
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.frame = frame
                layer.path = Self.chevronPath(size: chevronSize)
                applyChevronStyle(layer, hovered: isHoveredFold(desc.foldId))
                layer.setValue(desc.expanded ? CGFloat.pi / 2 : 0,
                               forKeyPath: "transform.rotation.z")
                CATransaction.commit()
            } else {
                if layer.frame != frame {
                    layer.frame = frame
                    layer.path = Self.chevronPath(size: chevronSize)
                }
                applyChevronStyle(layer, hovered: isHoveredFold(desc.foldId))
                layer.setValue(desc.expanded ? CGFloat.pi / 2 : 0,
                               forKeyPath: "transform.rotation.z")
            }
        }
        // Drop sublayers whose foldId no longer appears in the layout
        // (group collapsed → child chevrons removed from the table of
        // contents). Without this, stale chevrons linger as ghost
        // glyphs over the next layout below them.
        for (id, layer) in chevronLayers where !seen.contains(id) {
            layer.removeFromSuperlayer()
            chevronLayers.removeValue(forKey: id)
        }
    }

    /// Per-header descriptor passed from `ToolGroupLayout` to the
    /// chevron sublayer sync — already offset into cell-local coords
    /// by `layoutOrigin` so the cell does no extra math at fix-up time.
    private struct ChevronDescriptor {
        let foldId: UUID
        let center: CGPoint
        let expanded: Bool
    }

    private func chevronDescriptors(in tg: ToolGroupLayout) -> [ChevronDescriptor] {
        let origin = layoutOrigin
        var out: [ChevronDescriptor] = []
        out.reserveCapacity(1 + tg.items.count)
        out.append(ChevronDescriptor(
            foldId: tg.groupHeader.foldId,
            center: CGPoint(x: origin.x + tg.groupHeader.chevronCenter.x,
                             y: origin.y + tg.groupHeader.chevronCenter.y),
            expanded: tg.groupHeader.chevronExpanded))
        for entry in tg.items {
            out.append(ChevronDescriptor(
                foldId: entry.header.foldId,
                center: CGPoint(x: origin.x + entry.header.chevronCenter.x,
                                 y: origin.y + entry.header.chevronCenter.y),
                expanded: entry.header.chevronExpanded))
        }
        return out
    }

    private func makeChevronShapeLayer() -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.fillColor = nil
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.lineWidth = BlockStyle.toolHeaderChevronLineWidth
        // Chevrons composite above per-entry subview layers (which
        // live in `cell.layer.sublayers` at default zPosition = 0
        // alongside these shape layers). Without an explicit
        // zPosition, sublayer order depends on `addSubview` /
        // `addSublayer` call order — adding entry views after
        // chevron sublayers would bury the chevron. zPosition is the
        // CoreAnimation-blessed way to pin compositing order
        // independent of add order.
        layer.zPosition = 1
        // `position` action stays at its default `CABasicAnimation`
        // so chevrons slide alongside their sibling entry's
        // `view.animator().frame` during a fold transition — `position`
        // is `(layoutOrigin + chevronCenter)`, which moves when an
        // upstream child expands. `bounds` / `frame` / `path` / colour
        // / opacity stay NSNull-suppressed so a window resize doesn't
        // lerp glyph metrics or theme swaps. Resize itself is
        // safeguarded too — `Coordinator.invalidate(rows:)` wraps
        // its work in `CATransaction.setDisableActions(true)`, which
        // overrides the per-layer position action and forces the
        // chevron to snap.
        layer.actions = [
            "bounds": NSNull(),
            "frame": NSNull(),
            "path": NSNull(),
            "strokeColor": NSNull(),
            "opacity": NSNull(),
        ]
        layer.contentsScale = self.layer?.contentsScale ?? 2
        return layer
    }

    private func applyChevronStyle(_ layer: CAShapeLayer, hovered: Bool) {
        let strokeColor: NSColor = hovered
            ? BlockStyle.toolHeaderHoverForeground
            : BlockStyle.toolHeaderForeground
        let alpha: CGFloat = hovered
            ? BlockStyle.toolHeaderChevronHoverAlpha
            : BlockStyle.toolHeaderChevronIdleAlpha
        layer.strokeColor = strokeColor.cgColor
        layer.opacity = Float(alpha)
    }

    private func isHoveredFold(_ id: UUID) -> Bool {
        if case .toggleFold(let hoverId) = hoveredAction, hoverId == id {
            return true
        }
        return false
    }

    /// Refresh chevron colour / opacity in response to a `hoveredAction`
    /// transition — cheap, doesn't change geometry.
    private func updateChevronHoverStyles() {
        guard !chevronLayers.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, layer) in chevronLayers {
            applyChevronStyle(layer, hovered: isHoveredFold(id))
        }
        CATransaction.commit()
    }

    /// Two-segment `>` stroke path, geometric centre at the layer's
    /// bounds centre. Identical recipe to `GroupSideCar.chevronPath`.
    private static func chevronPath(size: CGFloat) -> CGPath {
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let mid = CGPoint(x: rect.midX, y: rect.midY)
        let halfW = size * 0.22
        let halfH = size * 0.4
        let path = CGMutablePath()
        path.move(to: CGPoint(x: mid.x - halfW, y: mid.y - halfH))
        path.addLine(to: CGPoint(x: mid.x + halfW, y: mid.y))
        path.addLine(to: CGPoint(x: mid.x - halfW, y: mid.y + halfH))
        return path
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

    // MARK: - Entry subviews (toolGroup)

    /// Set by `Transcript2Coordinator.toggleFold` before the
    /// upcoming `reloadData`. The next `syncEntrySubviews()` then
    /// routes frame updates through `view.animator()` so each entry
    /// slides over the fold-animation duration; subsequent
    /// non-fold layout swaps (resize, scroll recycle) consume no
    /// flag and snap frames as usual.
    func beginEntryFrameAnimation() {
        pendingEntryAnimation = true
    }

    /// Reconcile per-entry subviews against the current layout.
    /// Adds / removes / repositions one `ToolGroupEntryView` per
    /// `ToolGroupLayout.Entry`. For non-toolGroup layouts, drops
    /// every entry view.
    private func syncEntrySubviews() {
        guard case .toolGroup(let tg) = layout else {
            for (_, view) in entryViews { view.removeFromSuperview() }
            entryViews.removeAll()
            pendingEntryAnimation = false
            return
        }

        let animate = pendingEntryAnimation
        pendingEntryAnimation = false
        let origin = layoutOrigin
        let hoveredId = ToolGroupLayout.hoveredFoldId(in: hoveredAction)
        let layoutSelectionRects = computeToolGroupSelectionRects(layout: tg)

        var seen = Set<UUID>()
        for entry in tg.items {
            seen.insert(entry.childId)
            let frame = CGRect(
                x: origin.x + entry.bandRect.minX,
                y: origin.y + entry.bandRect.minY,
                width: entry.bandRect.width,
                height: entry.bandRect.height)

            let view: ToolGroupEntryView
            if let existing = entryViews[entry.childId] {
                view = existing
                if animate {
                    view.animator().frame = frame
                } else {
                    view.frame = frame
                }
            } else {
                view = ToolGroupEntryView(frame: frame)
                entryViews[entry.childId] = view
                addSubview(view)
            }

            // Order: chevron sublayers live above subviews
            // (`zPosition`) — entry subviews stay at the default 0 so
            // chevron glyphs paint on top of the body card. Subview
            // ordering among entries doesn't matter (their bands
            // don't overlap).

            view.entry = entry
            view.hovered = hoveredId == entry.header.foldId
            view.selectionRects = layoutSelectionRects
        }

        for (id, view) in entryViews where !seen.contains(id) {
            view.removeFromSuperview()
            entryViews.removeValue(forKey: id)
        }
    }

    /// Selection rects in `ToolGroupLayout`-local coords for the
    /// current `selection` value. Returns empty when there's no
    /// selection or the layout's adapter declines it. Distributed
    /// to every entry subview so each one can filter against its
    /// `bandRect` at draw time — the rect list is small (≤ N body
    /// rows) so the per-subview filter is cheaper than partitioning
    /// up front.
    private func computeToolGroupSelectionRects(layout tg: ToolGroupLayout) -> [CGRect] {
        guard let selection, let adapter = tg.selectionAdapter else { return [] }
        return adapter.rects(selection.start, selection.end)
    }

    /// Push the freshest selection rects to every entry subview.
    /// Triggered by `selection.didSet`; the views' own `didSet` on
    /// the property handles `needsDisplay` if the rect set changed.
    private func pushSelectionToEntrySubviews() {
        guard case .toolGroup(let tg) = layout, !entryViews.isEmpty else { return }
        let rects = computeToolGroupSelectionRects(layout: tg)
        for (_, view) in entryViews {
            view.selectionRects = rects
        }
    }

    /// Refresh hover flag on each entry subview after `hoveredAction`
    /// flips. Cheap — title colour swap is the only visual outcome
    /// and the view's `hovered.didSet` absorbs no-op assignments.
    private func updateEntrySubviewHoverStates() {
        guard !entryViews.isEmpty else { return }
        let hoveredId = ToolGroupLayout.hoveredFoldId(in: hoveredAction)
        for (_, view) in entryViews {
            view.hovered = (hoveredId == view.entry?.header.foldId)
        }
    }
}

/// Layer-backed subview rendering a single `ToolGroupLayout.Entry`.
/// Owned by `BlockCellView` for toolGroup rows; one instance per
/// `ToolGroupLayout.Entry`. The instance's `frame` is the entry's
/// `bandRect` in cell-local coords — animating that frame via
/// `view.animator().frame` (driven from the coordinator's
/// `NSAnimationContext.runAnimationGroup`) is what slides entries
/// below an expanding child.
///
/// **Hit-test passthrough.** `hitTest` returns `nil` so cell-level
/// mouseDown / hover tracking sees the cursor as if the subview
/// weren't there. The cell owns every interaction (fold toggle,
/// selection drag, link click); the subview only owns drawing.
final class ToolGroupEntryView: NSView {
    /// Entry data backing this view's draw. Reassigned on every
    /// layout swap; absent entries are removed (not nil-ed).
    var entry: ToolGroupLayout.Entry? {
        didSet { needsDisplay = true }
    }

    /// `true` when the cell's `hoveredAction` matches this entry's
    /// header `foldId` — flips the title colour to
    /// `toolHeaderHoverForeground` at draw time. Chevron alpha is
    /// independent (driven by the cell's per-foldId `CAShapeLayer`).
    var hovered: Bool = false {
        didSet { if hovered != oldValue { needsDisplay = true } }
    }

    /// Selection rects in toolGroup layout-local coords. Cell
    /// distributes the full list to every entry view; `drawEntry`
    /// filters to those intersecting `bandRect`. Equality check
    /// keeps redraw count tight when the rect list is unchanged.
    var selectionRects: [CGRect] = [] {
        didSet { if selectionRects != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // `.topLeft` anchors the redrawn bitmap to the top-left
        // corner — during a frame.size animation (driven by the
        // cell's `animator().frame`), the bitmap stays at its
        // natural size and the layer's `masksToBounds` clipping
        // crops as bounds interpolate. Default `.resize` would
        // stretch the bitmap vertically, distorting glyph metrics
        // while the entry's height eases between old and new.
        layer?.contentsGravity = .topLeft
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Hand mouse hits up to the cell — cell owns hover tracking,
    /// fold-toggle clicks, and selection drag. Without this, the
    /// subview captures `mouseDown` and the cell never sees it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let entry, let ctx = NSGraphicsContext.current?.cgContext else {
            return
        }
        let selectionColor: NSColor = (window?.isKeyWindow == true)
            ? .selectedTextBackgroundColor
            : .unemphasizedSelectedTextBackgroundColor
        ToolGroupLayout.drawEntry(
            entry,
            hovered: hovered,
            selectionRects: selectionRects,
            selectionColor: selectionColor,
            in: ctx)
    }
}
