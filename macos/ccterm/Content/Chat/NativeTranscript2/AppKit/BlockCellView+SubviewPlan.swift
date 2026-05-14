import AppKit
import QuartzCore

/// Subview-plan reconcile path for `BlockCellView`.
///
/// Some layouts (today only `toolGroup`) need AppKit-side adornments
/// the cell's CGContext draw can't express on its own:
///
/// - **Chevron glyphs.** `CAShapeLayer` sublayers per foldable header
///   so `transform.rotation.z` can be animated via `CABasicAnimation`
///   (rotation is far simpler than re-driving CGContext glyph strokes
///   from a display link).
/// - **Body subviews.** Layer-backed `ToolGroupEntryView` per expanded
///   entry so `view.animator().frame` can slide sibling entries when
///   an upstream child expands. Inside a single row, the row-height
///   transition alone gives a fade — only per-subview frame animation
///   produces the slide the user sees.
///
/// `RowLayout.subviewPlan(origin:hoveredAction:selection:)` returns a
/// `SubviewPlan` describing what the cell should host. The cell's
/// `syncSubviewPlan()` runs a generic reconcile against the plan — no
/// knowledge of `ToolGroupLayout` or its `Entry` type leaks past the
/// plan boundary. New adornment-bearing layouts add a `case .toolGroup`-
/// style arm to `RowLayout.subviewPlan` and emit specs from there;
/// nothing in this file changes.
///
/// ### Animation policy (chevron position)
///
/// First placement of a fresh chevron layer happens inside
/// `setDisableActions(true)` so the initial position set doesn't lerp
/// from `(0, 0)`. Repositions of an existing layer let the *surrounding*
/// CATransaction decide: during a fold transition,
/// `Coordinator.toggleFold`'s `NSAnimationContext.runAnimationGroup` is
/// active → chevron `position` slides over `foldAnimationDuration`,
/// matching the entry's `animator().frame` slide. Outside of that —
/// e.g. window resize, which wraps in `setDisableActions(true)` —
/// actions stay disabled and chevron snaps. `makeChevronShapeLayer`
/// NSNull-s `bounds` / `frame` / `path` / colour / opacity so only
/// `position` participates in the implicit animation channel.

extension BlockCellView {

    /// Rebuild the layout's `SubviewPlan` against current cell state
    /// and reconcile `chevronLayers` / `entryViews` with it. Called
    /// from every `didSet` that affects the plan: `layout`, `padTop`,
    /// `hoveredAction`, `selection`. Cheap — plan build is value
    /// composition; reconcile early-exits when nothing changed.
    func syncSubviewPlan() {
        let plan = layout?.subviewPlan(
            origin: layoutOrigin,
            hoveredAction: hoveredAction,
            selection: selection) ?? .empty
        let animateFrames = pendingFoldTransition
        pendingFoldTransition = false
        applyChevronPlan(plan.chevrons)
        applyEntryPlan(plan.entries, animateFrames: animateFrames)
    }

    /// Coordinator entry point for a fold toggle. Captures the
    /// chevron's current presentation-tree rotation, snaps the model
    /// rotation, schedules the explicit rotation animation, adds a
    /// `CATransition.fade` on the cell layer (so the new bitmap fades
    /// in rather than pops), and arms the one-shot
    /// `pendingFoldTransition` flag that the upcoming
    /// `syncSubviewPlan()` consumes to route entry-frame updates
    /// through `view.animator()`.
    ///
    /// Must be called *before* the coordinator's `reloadData`. The
    /// `reloadData` reuses the same cell for the same row, so the
    /// rotation animation and the cell-layer transition carry through
    /// the `layout` swap that follows.
    func beginFoldTransition(foldId: UUID, toExpanded: Bool) {
        if let layer = chevronLayers[foldId] {
            let presValue = layer.presentation()?
                .value(forKeyPath: "transform.rotation.z") as? CGFloat
            let modelValue = (layer.value(forKeyPath: "transform.rotation.z") as? CGFloat) ?? 0
            let fromAngle = presValue ?? modelValue
            let toAngle: CGFloat = toExpanded ? .pi / 2 : 0

            // Snap the model value inside a disabled-actions
            // transaction so the implicit `transform.rotation.z`
            // action doesn't double-animate against the explicit
            // CABasicAnimation we're about to add. (Same recipe as
            // the old `GroupSideCar.sync`.)
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

        // Cross-fade the cell's CGContext-drawn contents over the
        // same duration. `CATransition` on the host layer is the
        // AppKit-blessed way to do this — QuartzCore handles the
        // bitmap diff between the layer's old snapshot and its
        // post-redraw state. Chevron sublayers run their own
        // `CABasicAnimation` independently.
        if let hostLayer = self.layer {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = BlockStyle.foldAnimationDuration
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            hostLayer.add(transition, forKey: "contentFade")
        }

        pendingFoldTransition = true
    }

    // MARK: - Reconcile

    private func applyChevronPlan(_ specs: [SubviewPlan.Chevron]) {
        guard let hostLayer = self.layer else {
            // Without a host layer there's nowhere to attach
            // sublayers; drop any stragglers and bail.
            for (_, layer) in chevronLayers { layer.removeFromSuperlayer() }
            chevronLayers.removeAll()
            return
        }
        let chevronSize = BlockStyle.toolHeaderChevronSize
        var seen = Set<UUID>()

        for spec in specs {
            seen.insert(spec.id)
            let frame = CGRect(
                x: spec.center.x - chevronSize / 2,
                y: spec.center.y - chevronSize / 2,
                width: chevronSize, height: chevronSize)

            if let layer = chevronLayers[spec.id] {
                if layer.frame != frame {
                    layer.frame = frame
                    layer.path = Self.chevronPath(size: chevronSize)
                }
                applyChevronStyle(layer, spec: spec)
                layer.setValue(spec.expanded ? CGFloat.pi / 2 : 0,
                               forKeyPath: "transform.rotation.z")
            } else {
                let layer = makeChevronShapeLayer()
                chevronLayers[spec.id] = layer
                hostLayer.addSublayer(layer)
                // Initial placement: snap (otherwise the fresh
                // layer's `(0, 0) → spec.center` move would lerp
                // under any active CATransaction).
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.frame = frame
                layer.path = Self.chevronPath(size: chevronSize)
                applyChevronStyle(layer, spec: spec)
                layer.setValue(spec.expanded ? CGFloat.pi / 2 : 0,
                               forKeyPath: "transform.rotation.z")
                CATransaction.commit()
            }
        }

        // Drop sublayers whose id no longer appears in the plan
        // (group collapsed → child chevrons removed from the toc).
        // Without this, stale chevrons linger as ghost glyphs over
        // the next layout below them.
        for (id, layer) in chevronLayers where !seen.contains(id) {
            layer.removeFromSuperlayer()
            chevronLayers.removeValue(forKey: id)
        }
    }

    private func applyEntryPlan(
        _ specs: [SubviewPlan.Entry], animateFrames: Bool
    ) {
        var seen = Set<UUID>()
        for spec in specs {
            seen.insert(spec.id)
            if let view = entryViews[spec.id] {
                if view.frame != spec.frame {
                    if animateFrames {
                        view.animator().frame = spec.frame
                    } else {
                        view.frame = spec.frame
                    }
                }
                view.spec = spec
            } else {
                let view = ToolGroupEntryView(frame: spec.frame)
                view.spec = spec
                entryViews[spec.id] = view
                addSubview(view)
                // Order: chevron sublayers live above subviews
                // (`zPosition = 1` in `makeChevronShapeLayer`) so
                // chevron glyphs paint on top of the body card.
                // Subview ordering among entries doesn't matter
                // (their bands don't overlap).
            }
        }
        for (id, view) in entryViews where !seen.contains(id) {
            view.removeFromSuperview()
            entryViews.removeValue(forKey: id)
        }
    }

    // MARK: - Chevron layer construction

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

    private func applyChevronStyle(_ layer: CAShapeLayer, spec: SubviewPlan.Chevron) {
        layer.strokeColor = spec.strokeColor.cgColor
        layer.opacity = Float(spec.alpha)
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
}

/// Layer-backed subview rendering one `SubviewPlan.Entry`. Layout-
/// agnostic: holds the spec (id + frame + draw closure), invokes the
/// closure from `draw(_:)`. No knowledge of `ToolGroupLayout` or its
/// `Entry` shape — same recipe as `SelectionAdapter`: behavior is
/// packaged into closures captured over the immutable layout, the
/// consumer (view) only knows about the value type.
///
/// **Hit-test passthrough.** `hitTest` returns `nil` so cell-level
/// mouseDown / hover tracking sees the cursor as if the subview
/// weren't there. The cell owns every interaction (fold toggle,
/// selection drag, link click); the subview only owns drawing.
final class ToolGroupEntryView: NSView {
    /// Plan spec backing this view's draw. Reassigned on every
    /// reconcile; absent ids are removed (not nil-ed). Comparing
    /// specs cheaply is intentionally not modelled — `draw` closures
    /// are not `Equatable`, so the view re-paints on every spec set.
    /// The cell only sets `spec` when it has a fresh plan to push,
    /// which is bounded by `layout` / `hoveredAction` / `selection`
    /// transitions; per-frame re-paints during a fold animation come
    /// from `view.animator().frame` interpolation, not spec changes.
    var spec: SubviewPlan.Entry? {
        didSet { needsDisplay = true }
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
        guard let spec, let ctx = NSGraphicsContext.current?.cgContext else {
            return
        }
        // Selection colour depends on `window.isKeyWindow`, which is
        // a runtime cell-state — the plan can't bake it in at build
        // time. The view supplies it here and the closure paints
        // accordingly. Falls back to a sensible default when not in
        // a window (off-screen draw during view assembly).
        let selectionColor: NSColor = (window?.isKeyWindow == true)
            ? .selectedTextBackgroundColor
            : .unemphasizedSelectedTextBackgroundColor
        spec.draw(ctx, selectionColor)
    }
}
