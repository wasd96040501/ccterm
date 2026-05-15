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
        applyChevronPlan(plan.chevrons, allowSlide: animateFrames)
        applyEntryPlan(plan.entries, animateFrames: animateFrames)
        applyShimmerPlan(plan.shimmers)
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

    private func applyChevronPlan(
        _ specs: [SubviewPlan.Chevron], allowSlide: Bool
    ) {
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
                    // `position` is left as a default `CABasicAnimation`
                    // on the chevron layer (see `makeChevronShapeLayer`)
                    // so it can slide alongside its sibling entry's
                    // `view.animator().frame` during a fold transition.
                    // **Outside** a fold transition (cell reuse on
                    // session switch, scroll-driven reload, hover-
                    // induced layout swap) we don't want that implicit
                    // lerp — the chevron should snap to the new spec
                    // position. Wrap the reposition in
                    // `setDisableActions(true)` whenever
                    // `allowSlide == false`.
                    if allowSlide {
                        layer.frame = frame
                        layer.path = Self.chevronPath(size: chevronSize)
                    } else {
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        layer.frame = frame
                        layer.path = Self.chevronPath(size: chevronSize)
                        CATransaction.commit()
                    }
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

    /// Reconcile mask-swept title overlays against `specs`. One
    /// `ShimmerLayerSet` per running-header id:
    ///
    ///   • `text`: a `CALayer` whose `contents` is a CGImage of the
    ///     header title pre-rendered at the bright `.labelColor` tier.
    ///     Frame matches the title's natural CTLine bbox so the bright
    ///     glyphs sit pixel-aligned with where the cell bitmap *would*
    ///     have drawn the static title (the cell's `drawHeader` skips
    ///     the title pass when `wantsShimmer(for:)` is true, so this
    ///     is the only title rendering for the header).
    ///   • `mask`: a `CAGradientLayer` set as `text.mask`. Three-stop
    ///     alpha gradient `[base, 1.0, base]` runs a `locations`
    ///     keyframe from off-screen-left to off-screen-right so the
    ///     bright text shows at `base` alpha by default and pulses up
    ///     to full `.labelColor` along the swept stripe.
    ///
    /// **Hover combination.** When `spec.hovered` is true, the
    /// reconciler raises the mask's base alpha to `1.0` (via the
    /// "alphas" key on the gradient stops) so the title sits at full
    /// `.labelColor` end-to-end — same brightness non-running hovered
    /// headers reach through `titleColor(for:hovered:)`. The shimmer
    /// `locations` animation keeps running but is visually no-op since
    /// peak == base.
    ///
    /// Reuse policy: same set is reused across re-layouts so the
    /// running `locations` animation keeps cycling past
    /// `reloadData(forRowIndexes:)` (status flips, hover transitions).
    /// Image is re-rendered only when (title, font, scale) changes.
    private func applyShimmerPlan(_ specs: [SubviewPlan.Shimmer]) {
        guard let hostLayer = self.layer else {
            for (_, set) in shimmerLayers { set.text.removeFromSuperlayer() }
            shimmerLayers.removeAll()
            return
        }
        var seen = Set<UUID>()
        let scale = hostLayer.contentsScale
        for spec in specs {
            seen.insert(spec.id)
            let set = shimmerLayers[spec.id] ?? {
                let set = ShimmerLayerSet(scale: scale)
                shimmerLayers[spec.id] = set
                hostLayer.addSublayer(set.text)
                return set
            }()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if set.text.frame != spec.textRect {
                set.text.frame = spec.textRect
            }
            if set.mask.frame != set.text.bounds {
                set.mask.frame = set.text.bounds
            }
            // Image rebuild: skip when the cached key already covers
            // (title, font, appearance). NSImage handles backing-scale
            // re-renders internally (CALayer pulls
            // `layerContents(forContentsScale:)` on demand), so the
            // key doesn't need a `scale` axis. Appearance participates
            // because `.labelColor` resolves to different RGB in
            // Light vs. Dark — appearance flip must invalidate the
            // cached `NSImage`.
            let key = ShimmerLayerSet.ImageKey(
                title: spec.title,
                fontName: spec.font.fontName,
                pointSize: spec.font.pointSize,
                appearanceName: effectiveAppearance.name)
            if set.imageKey != key || set.text.contents == nil {
                set.text.contents = renderShimmerTitleImage(spec: spec)
                set.imageKey = key
            }
            // Mask alpha: hover wins (peak == base = 1.0), otherwise
            // sweep alternates base ↔ 1.0.
            let baseAlpha: CGFloat = spec.hovered
                ? 1.0
                : BlockStyle.toolHeaderShimmerBaseAlpha
            set.mask.colors = [
                NSColor.white.withAlphaComponent(baseAlpha).cgColor,
                NSColor.white.cgColor,
                NSColor.white.withAlphaComponent(baseAlpha).cgColor,
            ]
            CATransaction.commit()
            if set.mask.animation(forKey: Self.shimmerAnimationKey) == nil {
                set.mask.add(Self.makeShimmerAnimation(),
                             forKey: Self.shimmerAnimationKey)
            }
        }
        for (id, set) in shimmerLayers where !seen.contains(id) {
            set.text.removeFromSuperlayer()
            shimmerLayers.removeValue(forKey: id)
        }
    }

    /// Rasterise the bright-tier title via `NSImage(size:flipped:`
    /// `drawingHandler:)` + `NSAttributedString.draw(at:)`. Going
    /// through AppKit's high-level path (instead of constructing a
    /// `CGBitmapContext` by hand) gets us:
    ///
    ///   • Sub-pixel font positioning — the AppKit drawing context
    ///     ships with `CGContextSetShouldSubpixelPositionFonts(true)`
    ///     and friends already enabled, so retina glyphs land on
    ///     fractional pixel offsets without manual flag wrangling.
    ///   • LCD / grayscale font smoothing parity with the cell bitmap.
    ///   • Backing-scale awareness — `CALayer.contents = NSImage` makes
    ///     CoreAnimation pull `layerContents(forContentsScale:)` at
    ///     the host layer's `contentsScale`, which re-runs this
    ///     drawing handler at the correct pixel density. No manual
    ///     `scaleBy` ceremony, no rounding mismatch between bitmap
    ///     pixels and layer bounds.
    ///
    /// The handler runs inside `performAsCurrentDrawingAppearance` so
    /// `.labelColor` resolves against the cell's effective appearance
    /// (Light / Dark) rather than the app's main appearance. The
    /// `flipped: false` orientation matches `NSAttributedString.draw`'s
    /// "lower-left = origin" convention; `.draw(at: .zero)` puts the
    /// glyph baseline at `-descender` from the bottom, which lines up
    /// with `textRect`'s `(titleBaseline - ascender) ↔ titleBaseline`
    /// vertical span.
    private func renderShimmerTitleImage(spec: SubviewPlan.Shimmer) -> NSImage {
        let size = NSSize(width: spec.textRect.width,
                          height: spec.textRect.height)
        let appearance = effectiveAppearance
        return NSImage(size: size, flipped: false) { _ in
            appearance.performAsCurrentDrawingAppearance {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: spec.font,
                    .foregroundColor: BlockStyle.toolHeaderShimmerHighlight,
                ]
                NSAttributedString(string: spec.title, attributes: attrs)
                    .draw(at: .zero)
            }
            return true
        }
    }

    /// Build the mask's keyframe animation. `locations` slides
    /// through `[-1, -0.5, 0] → [1, 1.5, 2]` so the peak alpha stop
    /// enters from off-screen-left, crosses the title midline, and
    /// exits off-screen-right on each cycle. Linear timing keeps the
    /// perceived sweep velocity constant.
    private static func makeShimmerAnimation() -> CABasicAnimation {
        let anim = CABasicAnimation(keyPath: "locations")
        anim.fromValue = [-1.0, -0.5, 0.0] as [NSNumber]
        anim.toValue = [1.0, 1.5, 2.0] as [NSNumber]
        anim.duration = BlockStyle.toolHeaderShimmerDuration
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        anim.isRemovedOnCompletion = false
        return anim
    }

    private static let shimmerAnimationKey = "shimmer"

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

/// Two-layer pair backing one running header's shimmer:
///
///   • `text` is a plain `CALayer` whose `.contents` is a CGImage of
///     the title pre-rendered at full `.labelColor` brightness. The
///     reconciler refreshes the image whenever the cached `imageKey`
///     no longer matches (title / font / scale / appearance change).
///     `text` is what the cell actually composites onto its host
///     layer.
///   • `mask` is a horizontal `CAGradientLayer` set as `text.mask`.
///     The reconciler updates `colors` (`[white(α=base), white(α=1.0),
///     white(α=base)]`) and runs a `locations` keyframe that slides
///     the peak from off-screen-left to off-screen-right. With
///     `text.mask = mask`, the `text` layer's contents inherit the
///     mask alpha — bright glyphs show at `base` brightness most of
///     the time, peaking at `.labelColor` along the swept stripe.
///
/// Reuse: one set per running header `id`. The set survives
/// `reloadData(forRowIndexes:)` (recreated only when the spec drops
/// out of the plan), so the `locations` animation keeps cycling
/// without snapping back to its origin on every status flip.
final class ShimmerLayerSet {
    let text: CALayer
    let mask: CAGradientLayer
    /// Cache key for the rendered title image. Re-render is gated on
    /// inequality so unchanged shimmer specs (the common case during
    /// hover transitions or sibling row changes) don't burn CPU on
    /// CTLine + bitmap context construction every reconcile pass.
    /// Appearance-name participates because `.labelColor` resolves to
    /// different RGB across Light / Dark, so a system theme flip must
    /// invalidate the cached bitmap.
    var imageKey: ImageKey?

    struct ImageKey: Equatable {
        let title: String
        let fontName: String
        let pointSize: CGFloat
        let appearanceName: NSAppearance.Name
    }

    init(scale: CGFloat) {
        let text = CALayer()
        text.contentsScale = scale
        // Sit above per-entry subview layers so the shimmer composites
        // on top of child header surfaces (entry views are at default
        // zPosition = 0). Same recipe as `chevronLayers`.
        text.zPosition = 1
        text.contentsGravity = .resize
        // Suppress every implicit-animation channel on the host layer
        // — the only animation we want is the explicit `locations`
        // keyframe on the mask. An implicit `position` lerp triggered
        // by `frame =` would drag the bright text visibly across rows
        // on re-layouts (resize, layout swap).
        text.actions = [
            "bounds": NSNull(),
            "frame": NSNull(),
            "position": NSNull(),
            "contents": NSNull(),
            "opacity": NSNull(),
        ]

        let mask = CAGradientLayer()
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        mask.locations = [0, 0.5, 1]
        mask.contentsScale = scale
        mask.actions = [
            "bounds": NSNull(),
            "frame": NSNull(),
            "position": NSNull(),
            "colors": NSNull(),
            // `locations` is animated *explicitly* via CABasicAnimation;
            // suppress the implicit channel so `mask.locations =`
            // assignments outside the keyframe (none today, but
            // defensive) don't lerp against the running animation.
            "locations": NSNull(),
            "opacity": NSNull(),
            "startPoint": NSNull(),
            "endPoint": NSNull(),
        ]
        text.mask = mask
        self.text = text
        self.mask = mask
    }
}
