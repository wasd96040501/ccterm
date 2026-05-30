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
/// `RowLayout.subviewPlan(origin:hoveredAction:selection:copiedDiffIds:)` returns a
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
        let plan =
            layout?.subviewPlan(
                origin: layoutOrigin,
                hoveredAction: hoveredAction,
                selection: selection,
                searchHighlights: searchHighlights,
                flashingCopyIds: Set(copyFlashByActionId.keys)) ?? .empty
        let animateFrames = pendingFoldTransition
        pendingFoldTransition = false
        #if DEBUG
        if Transcript2PerfLog.enabled, !plan.entries.isEmpty {
            // Driven by `BlockCellView.{layout,padTop,hoveredAction,selection,`
            // `copyFlashByActionId,searchHighlights,setFrameSize,viewDidChangeBackingProperties}`.
            // We don't know the trigger here, but the call count alone
            // tells us whether scroll-without-mutation is producing
            // spurious plan rebuilds.
            Transcript2PerfLog.trace(
                "syncSubviewPlan entries=\(plan.entries.count) "
                    + "chevrons=\(plan.chevrons.count) "
                    + "shimmers=\(plan.shimmers.count) "
                    + "animateFrames=\(animateFrames)")
        }
        #endif
        applyChevronPlan(plan.chevrons, allowSlide: animateFrames)
        applyEntryPlan(plan.entries, animateFrames: animateFrames)
        applyShimmerPlan(plan.shimmers)
        applyLoadingDotsPlan(plan.loadingDots)
        applyUsagePlan(plan.usage)
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
            let presValue =
                layer.presentation()?
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

        beginContentFadeTransition()

        pendingFoldTransition = true
    }

    /// Cross-fade the cell's CGContext-drawn contents on the next
    /// redraw. `CATransition` on the host layer is the AppKit-blessed
    /// way to do this — QuartzCore handles the bitmap diff between
    /// the layer's old snapshot and its post-redraw state, so any
    /// sublayer animations (chevron rotation, shimmer sweep) keep
    /// running independently underneath.
    ///
    /// Must be called *before* the coordinator's `reloadData` for the
    /// same row, so the transition is queued on the layer that the
    /// upcoming `viewFor` will re-use. A no-op if the cell isn't
    /// layer-backed yet (cold dequeue path).
    ///
    /// Used by both `beginFoldTransition` (fold-driven layout swap)
    /// and the status-update path in `Transcript2Coordinator.setStatus`
    /// (tool-group header title / colour swap on `.running ↔
    /// .completed`). The duration matches `foldAnimationDuration` so
    /// both kinds of content swap share the same beat.
    func beginContentFadeTransition() {
        guard let hostLayer = self.layer else { return }
        let transition = CATransition()
        transition.type = .fade
        transition.duration = BlockStyle.foldAnimationDuration
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        hostLayer.add(transition, forKey: "contentFade")
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
                layer.setValue(
                    spec.expanded ? CGFloat.pi / 2 : 0,
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
                layer.setValue(
                    spec.expanded ? CGFloat.pi / 2 : 0,
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

    /// Reconcile shimmer overlay layers against `specs`. One
    /// `ShimmerLayerSet` per running-header id, composed as an
    /// **additive overlay** on top of the cell-bitmap base title:
    ///
    ///   • `text`: a `CALayer` whose `contents` is a CGImage of the
    ///     header title pre-rendered at the bright `.labelColor` tier
    ///     using the same `CTLine` typesetting the cell bitmap uses
    ///     for the base title (see `renderShimmerTitleImage`). The
    ///     bitmap encodes glyph alpha as the layer's alpha channel —
    ///     gap pixels around glyphs are transparent.
    ///   • `mask`: a `CAGradientLayer` set as `text.mask`. Three-stop
    ///     alpha gradient `[α=0, α=1, α=0]` runs a `locations`
    ///     keyframe from off-screen-left to off-screen-right. Effect:
    ///     overlay pixels are visible only along the swept stripe.
    ///
    /// **Compositing model.** Outside the stripe, mask α=0 → overlay
    /// pixels invisible → only the cell-bitmap base title (drawn at
    /// `.secondaryLabel`) shows. At the stripe peak, mask α=1 →
    /// overlay glyphs at full `.labelColor` opacity composite "over"
    /// the secondary base → labelColor wins where there's text. At
    /// the stripe edges (mask α 0→1), Porter-Duff "over" gives
    /// `result = label·α + secondary·(1−α)` per glyph pixel — a
    /// smooth brightness transition without per-pixel coverage drift.
    ///
    /// **Glyph alignment.** Critical to the "no smear" property: the
    /// overlay glyphs must land at the *same sub-pixel positions* as
    /// the cell-bitmap base glyphs. We achieve this by (a) rendering
    /// the overlay bitmap with the exact `CTLine` API the cell uses,
    /// and (b) injecting a sub-pixel `xOffset` (the fractional part
    /// of `textRect.minX` against the host backing scale's pixel
    /// grid) into the bitmap's `textPosition.x`. The layer frame
    /// itself is pixel-aligned to the backing scale so CALayer never
    /// resamples the bitmap. See `pixelAlignedFrame(for:scale:)`.
    ///
    /// **Hover combination.** Cell drawHeader paints the base title
    /// at `.labelColor` already when `hovered && running` (the
    /// `titleColor(for:hovered:)` palette is symmetric across
    /// running and completed). The overlay would just paint the same
    /// labelColor on top, contributing nothing — so we hide it
    /// (`text.opacity = 0`). The `locations` animation keeps cycling
    /// against an invisible layer; un-hovering snaps the overlay
    /// back into view mid-cycle without any phase reset.
    ///
    /// Reuse policy: same set is reused across re-layouts so the
    /// `locations` animation keeps cycling past
    /// `reloadData(forRowIndexes:)` (status flips, hover transitions,
    /// resize). Image is re-rendered only when (title, font,
    /// appearance, scale) changes.
    private func applyShimmerPlan(_ specs: [SubviewPlan.Shimmer]) {
        guard let hostLayer = self.layer else {
            for (_, set) in shimmerLayers { set.text.removeFromSuperlayer() }
            shimmerLayers.removeAll()
            return
        }
        var seen = Set<UUID>()
        let scale = max(hostLayer.contentsScale, 1)
        for spec in specs {
            seen.insert(spec.id)
            let set =
                shimmerLayers[spec.id]
                ?? {
                    let set = ShimmerLayerSet()
                    shimmerLayers[spec.id] = set
                    hostLayer.addSublayer(set.text)
                    return set
                }()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Pixel-align the overlay frame to the host backing
            // scale so CALayer never resamples the bitmap. The
            // residual sub-pixel offset between the layout's
            // `textRect.minX` and the aligned frame is folded into
            // the bitmap's `textPosition.x` so glyph 0 lands at the
            // same sub-pixel screen position as the cell-bitmap
            // base text — see `renderShimmerTitleImage`.
            let aligned = Self.pixelAlignedFrame(for: spec.textRect, scale: scale)
            let xOffset = spec.textRect.minX - aligned.minX
            let bottomPadding = aligned.maxY - spec.textRect.maxY
            if set.text.frame != aligned {
                set.text.frame = aligned
            }
            if set.mask.frame != set.text.bounds {
                set.mask.frame = set.text.bounds
            }
            // Sync contentsScale on every reconcile. The host
            // layer's scale can change after the set was created
            // (cell joined a window with different backingScale,
            // window dragged across displays, etc.); also covered
            // defensively by `viewDidChangeBackingProperties`,
            // which invalidates `imageKey` so the next reconcile
            // re-renders.
            if set.text.contentsScale != scale {
                set.text.contentsScale = scale
                set.mask.contentsScale = scale
            }
            // Cache key includes scale so a backing-scale change
            // forces a re-raster at the new pixel density. The
            // `xOffset` participates because changing it shifts the
            // bitmap glyph rasterization; same string at the same
            // font but a different sub-pixel x-offset is a
            // different bitmap.
            let key = ShimmerLayerSet.ImageKey(
                title: spec.title,
                fontName: spec.font.fontName,
                pointSize: spec.font.pointSize,
                appearanceName: effectiveAppearance.name,
                scale: scale,
                xOffset: xOffset,
                bottomPadding: bottomPadding,
                width: aligned.width,
                height: aligned.height)
            if set.imageKey != key || set.text.contents == nil {
                set.text.contents = renderShimmerTitleImage(
                    spec: spec,
                    bitmapSize: aligned.size,
                    xOffset: xOffset,
                    bottomPadding: bottomPadding)
                set.imageKey = key
            }
            // Hover: cell-bitmap base title is already at .labelColor,
            // so the overlay would paint redundant pixels. Hide it
            // entirely (animation keeps running on the invisible
            // layer so un-hovering picks up mid-cycle).
            set.text.opacity = spec.hovered ? 0 : 1
            CATransaction.commit()
            if set.mask.animation(forKey: Self.shimmerAnimationKey) == nil {
                set.mask.add(
                    Self.makeShimmerAnimation(),
                    forKey: Self.shimmerAnimationKey)
            }
        }
        for (id, set) in shimmerLayers where !seen.contains(id) {
            set.text.removeFromSuperlayer()
            shimmerLayers.removeValue(forKey: id)
        }
    }

    /// Pixel-align `rect` to the host backing `scale`'s pixel grid
    /// by flooring the min corner and ceiling the max corner. The
    /// resulting rect's edges land on integer pixel boundaries
    /// (`alignedRect.minX * scale` is an integer), so when assigned
    /// to a `CALayer.frame` the bitmap composites without resampling.
    /// The expanded width/height (≤ 1/scale extra on each side)
    /// covers both glyph drift slack and the sub-pixel `xOffset`
    /// needed for glyph alignment.
    nonisolated private static func pixelAlignedFrame(
        for rect: CGRect, scale: CGFloat
    ) -> CGRect {
        let minX = (rect.minX * scale).rounded(.down) / scale
        let minY = (rect.minY * scale).rounded(.down) / scale
        let maxX = (rect.maxX * scale).rounded(.up) / scale
        let maxY = (rect.maxY * scale).rounded(.up) / scale
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Rasterise the bright-tier title via `NSImage(size:flipped:`
    /// `drawingHandler:)` + `CTLineDraw`. Goes through the same
    /// Core Text path the cell bitmap uses for `drawHeader`, so
    /// glyph metrics, advances, and sub-pixel positioning behaviour
    /// are identical between the overlay and the base.
    ///
    ///   • `bitmapSize` is the pre-aligned overlay layer size in
    ///     points; the bitmap rasterises at `bitmapSize × scale`
    ///     pixels via NSImage's backing-scale-aware drawing handler.
    ///   • `xOffset` is the residual fractional offset between the
    ///     layout's `textRect.minX` and the pixel-aligned layer
    ///     frame's `minX`. Injected into `textPosition.x` so glyph 0
    ///     lands at the same sub-pixel screen position as the
    ///     cell-bitmap base title's glyph 0.
    ///   • `bottomPadding` is the vertical analog: the residual
    ///     padding between the title's `textRect.maxY` and the
    ///     pixel-aligned layer frame's `maxY` (≤ 1/scale points of
    ///     slack from the ceiling-rounded alignment). Folded into
    ///     `textPosition.y` along with `−font.descender` to put the
    ///     baseline at the right y-up position inside the bitmap.
    ///
    /// `flipped: false` matches `CTLineDraw`'s default y-up text
    /// matrix — no `textMatrix` wrangling needed inside the handler.
    /// The handler runs inside `performAsCurrentDrawingAppearance`
    /// so `.labelColor` resolves against the cell's effective
    /// appearance (Light / Dark) rather than the app's main
    /// appearance.
    private func renderShimmerTitleImage(
        spec: SubviewPlan.Shimmer,
        bitmapSize: CGSize,
        xOffset: CGFloat,
        bottomPadding: CGFloat
    ) -> NSImage {
        let size = NSSize(width: bitmapSize.width, height: bitmapSize.height)
        let appearance = effectiveAppearance
        let title = spec.title
        let font = spec.font
        // Baseline in y-up bitmap coords:
        //   • The cell's `textRect.maxY` (y-down) equals
        //     `baseline − descender` (descender < 0 → maxY > baseline).
        //   • The overlay frame's `aligned.maxY` extends past
        //     `textRect.maxY` by `bottomPadding` (≤ 1/scale points
        //     of ceiling-rounding slack).
        //   • Distance from bitmap bottom (y-up = 0) to baseline:
        //       (aligned.maxY − baseline)
        //     = (aligned.maxY − (textRect.maxY + descender))
        //     = (aligned.maxY − textRect.maxY) + (−descender)
        //     = bottomPadding + (−descender)
        let baselineY = bottomPadding + (-font.descender)
        return NSImage(size: size, flipped: false) { _ in
            appearance.performAsCurrentDrawingAppearance {
                guard let ctx = NSGraphicsContext.current?.cgContext else {
                    return
                }
                let attr = NSAttributedString(
                    string: title,
                    attributes: [
                        .font: font,
                        .foregroundColor: BlockStyle.toolHeaderShimmerHighlight,
                    ])
                let line = CTLineCreateWithAttributedString(attr)
                ctx.textPosition = CGPoint(x: xOffset, y: baselineY)
                CTLineDraw(line, ctx)
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

    // MARK: - Loading dots

    /// Reconcile the trailing "running" indicator against `spec`.
    /// Hosts a single `NSImageView` rendering SF Symbol `ellipsis`
    /// with `.variableColor.iterative.dimInactiveLayers.nonReversing`
    /// — Apple-tuned three-dot sequencing where inactive dots stay
    /// visible at a reduced opacity instead of disappearing
    /// entirely, so the three-point identity reads continuously and
    /// the active dot brightens out of an ambient row. Reduce Motion
    /// fallback handled by the framework. The view is reused across
    /// `reloadData(forRowIndexes:)` and resize so the symbol-effect
    /// loop keeps cycling without a phase reset. Cleared when the
    /// spec goes `nil`.
    private func applyLoadingDotsPlan(_ spec: SubviewPlan.LoadingDots?) {
        guard let spec else {
            if let view = loadingDotsImageView {
                view.removeAllSymbolEffects()
                view.removeFromSuperview()
                loadingDotsImageView = nil
            }
            return
        }
        let view: NSImageView
        if let existing = loadingDotsImageView {
            view = existing
        } else {
            view = NSImageView()
            view.imageScaling = .scaleProportionallyUpOrDown
            view.imageAlignment = .alignCenter
            view.symbolConfiguration = NSImage.SymbolConfiguration(
                pointSize: Self.loadingDotsSymbolPointSize, weight: .regular)
            view.image = NSImage(
                systemSymbolName: "ellipsis",
                accessibilityDescription: nil)
            view.contentTintColor = spec.tintColor
            addSubview(view)
            loadingDotsImageView = view
            view.addSymbolEffect(
                .variableColor.iterative.dimInactiveLayers.nonReversing,
                options: .repeating)
        }
        if view.frame != spec.frame {
            view.frame = spec.frame
        }
        if view.contentTintColor != spec.tintColor {
            view.contentTintColor = spec.tintColor
        }
    }

    /// SF Symbol point size for the running-indicator ellipsis. 13pt
    /// renders a glyph whose natural bounding box (~17×4) lines up
    /// with `BlockStyle.loadingPillWidth/Height`.
    nonisolated private static let loadingDotsSymbolPointSize: CGFloat = 13

    // MARK: - Usage counter

    /// Reconcile the live token-usage counter against `spec`. Hosts a single
    /// `LoadingPillUsageView` reused across `reloadData(forRowIndexes:)` so the
    /// odometer-style roll state carries through each `setTurnUsage` tick.
    /// Cleared when the spec goes `nil` (turn counted no tokens yet, or the row
    /// recycled to another kind).
    private func applyUsagePlan(_ spec: SubviewPlan.UsageCounter?) {
        guard let spec else {
            if let view = loadingPillUsageView {
                view.removeFromSuperview()
                loadingPillUsageView = nil
            }
            return
        }
        let view: LoadingPillUsageView
        if let existing = loadingPillUsageView {
            view = existing
        } else {
            view = LoadingPillUsageView(frame: spec.frame)
            addSubview(view)
            loadingPillUsageView = view
        }
        if view.frame != spec.frame {
            view.frame = spec.frame
        }
        view.apply(spec)
    }

    private func applyEntryPlan(
        _ specs: [SubviewPlan.Entry], animateFrames: Bool
    ) {
        var seen = Set<UUID>()
        #if DEBUG
        var perfReassignedSpec = 0
        var perfNewView = 0
        var perfFrameChanged = 0
        #endif
        for spec in specs {
            seen.insert(spec.id)
            if let view = entryViews[spec.id] {
                if view.frame != spec.frame {
                    if animateFrames {
                        view.animator().frame = spec.frame
                    } else {
                        view.frame = spec.frame
                    }
                    #if DEBUG
                    perfFrameChanged += 1
                    #endif
                }
                view.spec = spec
                #if DEBUG
                perfReassignedSpec += 1
                #endif
            } else {
                let view = ToolGroupEntryView(frame: spec.frame)
                view.spec = spec
                entryViews[spec.id] = view
                addSubview(view)
                #if DEBUG
                perfNewView += 1
                #endif
                // Order: chevron sublayers live above subviews
                // (`zPosition = 1` in `makeChevronShapeLayer`) so
                // chevron glyphs paint on top of the body card.
                // Subview ordering among entries doesn't matter
                // (their bands don't overlap).
            }
        }
        #if DEBUG
        var perfRemoved = 0
        #endif
        for (id, view) in entryViews where !seen.contains(id) {
            view.removeFromSuperview()
            entryViews.removeValue(forKey: id)
            #if DEBUG
            perfRemoved += 1
            #endif
        }
        #if DEBUG
        if Transcript2PerfLog.enabled, !specs.isEmpty {
            // Spec reassignment counts surface "spec churn" cleanly:
            // every reassigned spec triggers `ToolGroupEntryView.spec`'s
            // `didSet` → `needsDisplay = true`, even when the spec's
            // observable content was unchanged. A high count on a pure
            // scroll proves we're invalidating entry bitmaps for no
            // visible reason.
            Transcript2PerfLog.trace(
                "applyEntryPlan specs=\(specs.count) "
                    + "new=\(perfNewView) reused=\(perfReassignedSpec) "
                    + "frameChanged=\(perfFrameChanged) removed=\(perfRemoved) "
                    + "animateFrames=\(animateFrames)")
        }
        #endif
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
        // Resolve under the cell's effective appearance so dynamic
        // colours (`labelColor` / `secondaryLabelColor` / …) pick the
        // right RGB for Light vs Dark. `CAShapeLayer.strokeColor` is a
        // static `CGColor` — without this hook a chevron created in
        // Light mode keeps its Light RGB when the user flips to Dark.
        // `viewDidChangeEffectiveAppearance` re-runs `syncSubviewPlan`
        // which lands back here under the new appearance.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.strokeColor = spec.strokeColor.cgColor
        }
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
        // Trust AppKit's `dirtyRect` verbatim. Intersecting with
        // `visibleRect` first was unsafe under the tile-on-demand
        // fallback that kicks in when the entry view's layer exceeds
        // the IOSurface single-texture cap (~16 384 px): AppKit/
        // CoreAnimation can issue `draw(_:)` for tiles that haven't
        // entered `visibleRect` yet (pre-render ahead of scroll, or
        // a draw cycle whose visibleRect cache hasn't caught up with
        // the clipview's current scroll position). Intersecting with
        // `visibleRect` collapsed those calls to an empty rect, the
        // early-return skipped the tile, and CoreAnimation cached an
        // empty bitmap for it — when the user scrolled into that
        // band, blank pixels showed for several seconds until some
        // later invalidation forced a redraw.
        //
        // The per-row dirty filter inside `DiffLayout.draw` /
        // `drawBackplate` already collapses per-call work to
        // O(rows ∩ dirtyRect), which is what the perf measurement in
        // PR #156 actually relied on. In tile mode `dirtyRect` is
        // already tile-sized, so removing the `visibleRect` narrowing
        // is a no-op for scroll cost.
        #if DEBUG
        // Entry-view repaint trace. This is the single biggest scroll-
        // cost path for a tool group whose expanded child overflows
        // the viewport — the entry view's CALayer-backed bitmap is the
        // diff body, sized to `entry.bandRect.height`. If this fires
        // during scroll-without-mutation, the cached bitmap is missing
        // (almost certainly because the layer's intrinsic size hit
        // IOSurface limits and CoreAnimation fell back to tiled
        // on-demand drawing). The dirtyRect.height vs bounds.height
        // ratio + repaint count per scroll-frame surfaces that fast.
        let perfStart =
            Transcript2PerfLog.enabled ? CFAbsoluteTimeGetCurrent() : 0
        defer {
            if Transcript2PerfLog.enabled {
                let ms = (CFAbsoluteTimeGetCurrent() - perfStart) * 1000
                Transcript2PerfLog.trace(
                    "ToolGroupEntryView.draw id=\(spec.id.uuidString.prefix(8)) "
                        + "bounds=\(BlockCellView.fmt(bounds.size)) "
                        + "dirty=\(BlockCellView.fmt(dirtyRect.size)) "
                        + "ms=\(String(format: "%.2f", ms))")
            }
        }
        #endif
        if dirtyRect.isEmpty { return }
        // Selection colour depends on `window.isKeyWindow`, which is
        // a runtime cell-state — the plan can't bake it in at build
        // time. The view supplies it here and the closure paints
        // accordingly. Falls back to a sensible default when not in
        // a window (off-screen draw during view assembly).
        let isKey = window?.isKeyWindow == true
        let selectionColor: NSColor =
            isKey
            ? .selectedTextBackgroundColor
            : .unemphasizedSelectedTextBackgroundColor
        spec.draw(
            ctx, selectionColor,
            BlockCellView.searchActiveFillColor(isKey: isKey),
            BlockCellView.searchInactiveFillColor(isKey: isKey),
            dirtyRect)
    }
}

/// Two-layer pair backing one running header's additive shimmer
/// overlay:
///
///   • `text` is a plain `CALayer` whose `.contents` is a CGImage of
///     the title pre-rendered at full `.labelColor` brightness via
///     the same `CTLine` typesetting the cell bitmap uses for the
///     base title (see `renderShimmerTitleImage`). The bitmap's
///     alpha channel encodes glyph coverage — gap pixels are fully
///     transparent. The reconciler refreshes the image whenever the
///     cached `imageKey` no longer matches.
///   • `mask` is a horizontal `CAGradientLayer` set as `text.mask`.
///     Colors are fixed at `[α=0, α=1, α=0]` (constructor) so the
///     overlay is visible only along the moving stripe. A
///     `locations` keyframe slides the peak from off-screen-left to
///     off-screen-right.
///
/// **Compositing:** the overlay sits on top of the cell-bitmap base
/// title (which is always drawn at the static `secondaryLabel` /
/// hover-tier `labelColor` palette via `drawHeader`). Outside the
/// stripe, mask α=0 → overlay invisible → only base shows. At the
/// stripe peak, mask α=1 → labelColor glyphs composite "over" the
/// secondary base → labelColor wins where there's text. Glyph
/// alignment between overlay and base is sub-pixel-perfect via the
/// reconciler's `xOffset` injection — see `applyShimmerPlan`.
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
    ///
    /// Axes:
    ///   • `appearanceName` — `.labelColor` resolves to different RGB
    ///     across Light / Dark, so a theme flip must re-raster.
    ///   • `scale` — backing-scale change (window dragged across
    ///     displays) shifts pixel density; bitmap must re-raster.
    ///   • `xOffset` — sub-pixel x-offset injected for glyph
    ///     alignment with the cell-bitmap base; a different offset
    ///     gives a different glyph rasterization.
    ///   • `bottomPadding` — ceiling-rounding slack at the bottom
    ///     of the aligned frame; participates because the bitmap's
    ///     baseline y depends on it.
    ///   • `width` / `height` — the pixel-aligned bitmap canvas;
    ///     resize requires a fresh bitmap at the new dimensions.
    var imageKey: ImageKey?

    struct ImageKey: Equatable {
        let title: String
        let fontName: String
        let pointSize: CGFloat
        let appearanceName: NSAppearance.Name
        let scale: CGFloat
        let xOffset: CGFloat
        let bottomPadding: CGFloat
        let width: CGFloat
        let height: CGFloat
    }

    init() {
        let text = CALayer()
        // Sit above per-entry subview layers so the shimmer composites
        // on top of child header surfaces (entry views are at default
        // zPosition = 0). Same recipe as `chevronLayers`.
        text.zPosition = 1
        // `.topLeft` (not `.resize`) so the bitmap's pixel grid maps
        // 1:1 onto the layer's pixel grid. Combined with the
        // reconciler's pixel-aligned frame, CALayer never resamples
        // the bitmap — glyphs stay bit-exact.
        text.contentsGravity = .topLeft
        // Suppress every implicit-animation channel on the host layer
        // — the only animation we want is the explicit `locations`
        // keyframe on the mask. An implicit `position` lerp triggered
        // by `frame =` would drag the bright text visibly across rows
        // on re-layouts (resize, layout swap). `opacity` is
        // suppressed too so the hover-driven hide/show snaps rather
        // than fading.
        text.actions = [
            "bounds": NSNull(),
            "frame": NSNull(),
            "position": NSNull(),
            "contents": NSNull(),
            "contentsScale": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull(),
        ]

        let mask = CAGradientLayer()
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        mask.locations = [0, 0.5, 1]
        // Mask colors are immutable for the life of the set —
        // `[α=0, α=1, α=0]` always. Hover state is handled by
        // toggling `text.opacity` on the host layer, not by
        // re-shading the mask. This keeps the GPU's gradient
        // texture cache stable across hover transitions.
        mask.colors = [
            NSColor.white.withAlphaComponent(0).cgColor,
            NSColor.white.cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
        ]
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
            "contentsScale": NSNull(),
            "startPoint": NSNull(),
            "endPoint": NSNull(),
        ]
        text.mask = mask
        self.text = text
        self.mask = mask
    }
}
