import AppKit

/// Something a `MediaOverlayWindow` can show: a view that knows how big it wants
/// to be inside the space the overlay offers it.
///
/// One requirement, because that is the only decision the overlay cannot make.
/// A picture wants to be aspect-fitted; a message wants a readable column at full
/// height. Both are "given this rectangle, take the part of it you need".
@MainActor
public protocol MediaOverlayContent: NSView {

    /// The frame to take inside `available`, in the same coordinate space —
    /// the overlay's content view, y-up, already inset for the control bar.
    func overlayFrame(in available: NSRect) -> NSRect
}

/// The dark full-screen surface a picture or a cut-short message opens into.
///
/// Telegram's `GalleryViewer`, down to the mechanism: a **separate borderless
/// window**, transparent, sized to the screen, with the dimming drawn *inside*
/// it as an ordinary view rather than set as the window's own colour.
///
/// The split matters and is not decoration. The window contributes nothing but a
/// transparent canvas the size of the display; the 90%-black mask is a layer-
/// backed subview whose opacity animates from 0 to 1. That is what lets the host
/// window stay visible underneath while the picture flies out of the row it was
/// sitting in and the surround darkens around it — a window-level background
/// colour would be all-or-nothing and could not be animated apart from the
/// content.
///
/// ## What is Telegram's, and what is not
///
/// Telegram's, verbatim: the borderless transparent window, `.popUpMenu` level,
/// the black-at-90% mask, the 95-point bottom inset against a top inset of the
/// screen's own safe area, and the whole of `animate(oldRect:newRect:)` — two
/// views travelling one path on an overdamped spring, crossfading.
///
/// **Not** Telegram's: their gallery re-takes key on `windowDidResignKey`, which
/// makes it modal against the whole system — cmd-tab away and it pulls focus
/// back. Here the overlay is a **child window** of the host instead. It orders,
/// minimises and hides with the window whose transcript it came from, which is
/// both what a preview belonging to a document should do and the reason no focus
/// grab is needed to keep it in the right place. Their arrangement is right for
/// an app-global viewer; this one is right for a panel over a document.
///
/// ## There is no close button
///
/// Checked rather than assumed: `GalleryModernControls.layout()` places an avatar
/// at x = 80 and, on the right, zoom out / zoom in / rotate / fast save / share /
/// more. **No X, in either corner.** A gallery leaves by escape or by a click
/// outside the picture, and a chrome-free surround is most of why it reads as the
/// picture rather than as a window containing one.
///
/// So the two ways out are the only two, and both are made to work rather than
/// left to the responder chain:
///
/// - **Escape** goes through a local event monitor, not the window's `keyDown`.
///   A content that puts a selectable `NSTextView` on screen — which the rest of
///   a cut-short message will, whenever it is built — takes first responder, and
///   a text view swallows escape in `interpretKeyEvents` and hands nothing back
///   up, so the window is never asked. A monitor sees the key before dispatch and
///   is indifferent to who is focused. Kept although the only content today is an
///   image view, because the failure it avoids is silent and the monitor costs a
///   line.
/// - **A click outside** is `mouseDown` on the mask, which is exactly the region
///   that means "outside" — no hit-test arithmetic, and it stays right as the
///   content resizes.
@MainActor
public final class MediaOverlayWindow: NSObject {

    // MARK: - Telegram's constants

    /// `GalleryViewer`'s `NSColor.black.withAlphaComponent(0.9)`.
    private static let maskAlpha: CGFloat = 0.9

    /// `GalleryPageController`'s flight: `let duration: Double = 0.25`.
    private static let flightDuration: CFTimeInterval = 0.25

    /// `GalleryModernControls.animateIn`'s `duration: 0.2`, which the mask shares.
    private static let fadeDuration: CFTimeInterval = 0.2

    /// `GalleryPageController`'s `contentInset`: `bottom: 95`, and a top of the
    /// screen's own safe area — which on a notched display is the notch and on
    /// every other one is zero.
    private static let bottomInset: CGFloat = 95

    // MARK: -

    private let panel: OverlayPanel
    private let maskView = MaskView()
    private let content: MediaOverlayContent

    /// The source's own pixels, flying alongside the content. `nil` when the
    /// caller had none to give.
    private let sourceView: SnapshotView?
    private let sourceRect: NSRect
    private let topInset: CGFloat
    private weak var host: NSWindow?
    private var keyMonitor: Any?
    private var isDismissing = false

    /// Shows `content` over `hostView`'s window, flying it out of `sourceRect`.
    ///
    /// `sourceRect` is in `hostView`'s coordinates — the rectangle the reader
    /// pressed, which both callers already hold: `TranscriptKit` hands one over
    /// with a `More` press, and `ImageGridView` hands one over with a tile.
    ///
    /// The overlay on screen, and the **only** strong reference to it.
    ///
    /// Without this the instance dies the moment `present` returns: the panel
    /// survives because its parent window retains it, so the overlay appears
    /// perfectly — and then every way out of it goes through a `[weak self]` that
    /// is already `nil`, leaving a scrim nothing dismisses. A returned value the
    /// caller is expected to hold does not fix it either; a call site that opens
    /// a preview and forgets it is the normal one, not a mistake.
    ///
    /// Telegram holds the same reference for the same reason — a file-private
    /// `viewer`, with `showChatGallery` refusing to open a second one over it —
    /// and one at a time falls out rather than being decided: two full-screen
    /// scrims have no arrangement, and the second's mask would darken the first.
    private static var current: MediaOverlayWindow?

    /// Nothing happens if an overlay is already up, which is what keeps a
    /// double-click from opening two.
    ///
    /// `sourceSnapshot` is what the source *looked like* — the pixels that were on
    /// screen in `sourceRect`. It rides the flight as a second view crossfading
    /// against the content, which is the whole of what it is for; see `flight`.
    /// Passing `nil` gives a one-view flight, which is correct but shows the
    /// content squashed to the source's proportions for the first frames.
    @discardableResult
    public static func present(
        _ content: MediaOverlayContent, from sourceRect: NSRect, sourceSnapshot: NSImage?,
        in hostView: NSView
    ) -> MediaOverlayWindow? {
        guard current == nil, let host = hostView.window,
            let screen = host.screen ?? NSScreen.main
        else { return nil }
        // Two hops, because the overlay's window and the host's are different
        // windows on the same screen: view → host window → screen → here.
        let inScreen = host.convertToScreen(hostView.convert(sourceRect, to: nil))
        let overlay = MediaOverlayWindow(
            content: content, sourceRect: inScreen, sourceSnapshot: sourceSnapshot, host: host,
            screen: screen)
        overlay.show()
        return overlay
    }

    private init(
        content: MediaOverlayContent, sourceRect: NSRect, sourceSnapshot: NSImage?,
        host: NSWindow, screen: NSScreen
    ) {
        self.content = content
        self.sourceView = sourceSnapshot.map(SnapshotView.init)
        self.host = host
        self.topInset = screen.safeAreaInsets.top
        self.panel = OverlayPanel(
            contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        // Screen coordinates all the way in: the panel covers the screen exactly,
        // so its own space and the screen's differ only by the frame's origin.
        self.sourceRect = NSRect(
            x: sourceRect.minX - screen.frame.minX, y: sourceRect.minY - screen.frame.minY,
            width: sourceRect.width, height: sourceRect.height)
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu
        panel.hasShadow = false
        // The overlay is a scrim over one document, so it should not be a second
        // entry anywhere the system lists windows.
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]

        guard let container = panel.contentView else { return }
        container.wantsLayer = true

        maskView.wantsLayer = true
        maskView.layer?.backgroundColor =
            NSColor.black.withAlphaComponent(Self.maskAlpha).cgColor
        maskView.frame = container.bounds
        maskView.autoresizingMask = [.width, .height]
        maskView.onClick = { [weak self] in self?.dismiss() }
        container.addSubview(maskView)

        content.wantsLayer = true
        content.frame = content.overlayFrame(in: availableRect(in: container.bounds))
        container.addSubview(content)

        // Above the content, as Telegram adds its copy after its new view: for
        // most of the opening flight the copy is the thing being looked at, and
        // it has to be the thing on top for that to be true.
        if let sourceView {
            sourceView.wantsLayer = true
            sourceView.frame = self.sourceRect
            container.addSubview(sourceView)
        }
    }

    /// The space the content may take: the whole screen, less the screen's safe
    /// area at the top and Telegram's 95 at the bottom.
    private func availableRect(in bounds: NSRect) -> NSRect {
        NSRect(
            x: 0, y: Self.bottomInset, width: bounds.width,
            height: bounds.height - Self.bottomInset - topInset)
    }

    // MARK: - In

    private func show() {
        guard let host else { return }
        Self.current = self
        // Ordered above the host and owned by it: the overlay follows the window
        // whose transcript opened it, rather than floating over the system.
        host.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)

        // Ahead of the responder chain, and therefore ahead of a text view that
        // would otherwise eat it. Returning `nil` consumes the key so nothing
        // downstream sees an escape the overlay has already acted on.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53 else { return event }
            self.dismiss()
            return nil
        }

        maskView.layer?.opacity = 0
        animate(maskView.layer, key: "opacity", from: 0, to: 1, duration: Self.fadeDuration)
        maskView.layer?.opacity = 1

        flight(collapsed: sourceRect, expanded: content.frame, appearing: true)
    }

    // MARK: - Out

    /// Reverses everything `show` did, then takes the window away.
    ///
    /// Guarded against re-entry: escape and a click on the mask both land here,
    /// and a second one arriving mid-flight would start a second set of
    /// animations against a window already on its way out.
    public func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true

        // Before anything else. A monitor left installed keeps swallowing escape
        // for the rest of the process, which is a dead key nobody would connect
        // back to a preview that closed correctly.
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }

        animate(maskView.layer, key: "opacity", from: 1, to: 0, duration: Self.fadeDuration)
        maskView.layer?.opacity = 0
        flight(collapsed: sourceRect, expanded: content.frame, appearing: false)

        // Torn down after the flight rather than on its completion handler: the
        // handler would have to survive the layer it is attached to being removed,
        // and every path here takes the same fixed time.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flightDuration) { [weak self] in
            guard let self else { return }
            self.host?.removeChildWindow(self.panel)
            self.panel.orderOut(nil)
            // Last, and the line that actually releases this object: everything
            // above still needs it.
            if Self.current === self { Self.current = nil }
        }
    }

    // MARK: - The flight

    /// Telegram's `animate(oldRect:newRect:)` whole: **two** views travel the
    /// same path between the rectangle the reader pressed and the rectangle the
    /// content rests at, and which one is seen is decided by a crossfade rather
    /// than by the geometry.
    ///
    /// The second view is why this is not simply "animate the content". The two
    /// scales are independent — `x` from the widths, `y` from the heights — so at
    /// the collapsed end the content is *squashed to the source's proportions*.
    /// For a picture that is a real distortion, because the tile it came from was
    /// cropped by the mosaic and the preview is not cropped at all. The copy
    /// carries the source's own pixels, crop and rounded corners included, and it
    /// is opaque exactly where the content is squashed — so the squash is never on
    /// screen. Telegram copies the source view; here the caller hands over a still
    /// of it (`ImageGridView.snapshot(ofTile:)`), which comes to the same thing.
    ///
    /// The copy's scale runs the other way from the content's — 1 at the source
    /// and `expanded / collapsed` at the destination — because it is framed at the
    /// source's size where the content is framed at the destination's. Both
    /// therefore describe the same journey, and the pair is what makes the flight
    /// reversible: the exit is this with `appearing` false and nothing else
    /// changed.
    ///
    /// **The two rectangles keep their roles in both directions.** Telegram's
    /// routine means "old → new" and its callers swap the arguments to reverse it;
    /// this one names them for what they are. Not a stylistic preference — passing
    /// them the other way round on the way out is a bug this file shipped: the
    /// position animation ran from the rest position to the rest position (no
    /// movement at all) while the scale ran from 1 to `expanded / collapsed`,
    /// which is *larger* than one, and a layer whose `anchorPoint` is (0, 0) grows
    /// about its bottom-left corner in an unflipped window. The picture leapt up
    /// and to the right instead of shrinking back into its row.
    private func flight(collapsed: NSRect, expanded: NSRect, appearing: Bool) {
        guard expanded.width > 0, expanded.height > 0, collapsed.width > 0, collapsed.height > 0
        else { return }

        let scaleX = collapsed.width / expanded.width
        let scaleY = collapsed.height / expanded.height

        // The content: framed at `expanded`, so its rest state is the far end.
        fly(
            content, from: appearing ? collapsed.origin : expanded.origin,
            to: appearing ? expanded.origin : collapsed.origin,
            scaleFrom: appearing ? (scaleX, scaleY) : (1, 1),
            scaleTo: appearing ? (1, 1) : (scaleX, scaleY),
            alphaFrom: appearing ? 0 : 1, alphaTo: appearing ? 1 : 0,
            alphaOverHalf: appearing, hold: !appearing)

        // The copy: framed at `collapsed`, so its rest state is the near end, and
        // its scale runs the other way — 1 at the source, `expanded / collapsed`
        // at the destination. Its alpha is the mirror of the content's, which is
        // the entire trick: both views travel the same path, and which one the eye
        // sees is decided by the crossfade rather than by the geometry.
        guard let sourceView else { return }
        let inverseX = expanded.width / collapsed.width
        let inverseY = expanded.height / collapsed.height
        fly(
            sourceView, from: appearing ? collapsed.origin : expanded.origin,
            to: appearing ? expanded.origin : collapsed.origin,
            scaleFrom: appearing ? (1, 1) : (inverseX, inverseY),
            scaleTo: appearing ? (inverseX, inverseY) : (1, 1),
            alphaFrom: appearing ? 1 : 0, alphaTo: appearing ? 0 : 1,
            alphaOverHalf: false, hold: true)

        // Only on the way in: on the way out the whole window goes, and taking the
        // copy away early would show the content it was covering.
        if appearing {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.flightDuration) {
                [weak sourceView] in
                sourceView?.removeFromSuperview()
            }
        }
    }

    /// One view's half of the flight — the four animations, all of them Telegram's.
    ///
    /// `from`/`to` are **origins**, not centres. A layer-backed `NSView`'s layer
    /// has an `anchorPoint` of (0, 0) — measured, a view at (137, 421) reports
    /// `position` (137, 421) — so `position` *is* the frame's origin and the scale
    /// pivots on that same corner. Origin plus corner-pivoted scale maps one
    /// rectangle onto the other exactly, which is why their arithmetic looks wrong
    /// and is not.
    ///
    /// `hold` keeps the last frame instead of reverting to the layer's model
    /// values. Needed wherever the end of the animation is not where the layer
    /// actually is: the content on the way out, and the copy in both directions.
    private func fly(
        _ view: NSView, from: CGPoint, to: CGPoint, scaleFrom: (CGFloat, CGFloat),
        scaleTo: (CGFloat, CGFloat), alphaFrom: CGFloat, alphaTo: CGFloat, alphaOverHalf: Bool,
        hold: Bool
    ) {
        guard let layer = view.layer else { return }
        let anchor = layer.anchorPoint
        let size = view.frame.size

        func anchored(_ origin: CGPoint) -> CGPoint {
            CGPoint(x: origin.x + size.width * anchor.x, y: origin.y + size.height * anchor.y)
        }

        func add(_ keyPath: String, from: Any, to: Any, half: Bool = false) {
            let animation = Self.spring(keyPath, half: half)
            animation.fromValue = from
            animation.toValue = to
            animation.isRemovedOnCompletion = !hold
            layer.add(animation, forKey: keyPath)
        }

        add("position", from: NSValue(point: anchored(from)), to: NSValue(point: anchored(to)))
        add("transform.scale.x", from: scaleFrom.0, to: scaleTo.0)
        add("transform.scale.y", from: scaleFrom.1, to: scaleTo.1)
        add("opacity", from: alphaFrom, to: alphaTo, half: alphaOverHalf)
    }

    /// `makeSpringAnimation` from `CAAnimationUtils`, constants and all: a
    /// `CASpringAnimation` at mass 3, stiffness 1000, damping 500, no initial
    /// velocity, played linearly.
    ///
    /// Heavily **overdamped** — critical damping for that mass and stiffness is
    /// `2 * sqrt(3 * 1000) ≈ 110`, and this is 500 — so there is no bounce, only
    /// a very soft settle. That is the whole of the difference between this and
    /// the `easeOut` that was here before, and it is the difference between the
    /// flight reading as smooth and reading as a slide.
    ///
    /// Their duration trick comes with it: the spring's natural duration is 0.5
    /// and the caller wants 0.25, so rather than shortening the spring they run
    /// it at `speed = 0.5 / 0.25`. A spring re-timed by speed keeps its curve;
    /// one re-timed by duration does not.
    private static func spring(_ keyPath: String, half: Bool) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = 3
        animation.stiffness = 1000
        animation.damping = 500
        animation.initialVelocity = 0
        animation.duration = 0.5
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.speed = Float(animation.duration / (half ? flightDuration / 2 : flightDuration))
        animation.fillMode = .forwards
        return animation
    }

    private func animate(
        _ layer: CALayer?, key: String, from: CGFloat, to: CGFloat, duration: CFTimeInterval
    ) {
        guard let layer else { return }
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: key)
    }
}

// MARK: -

/// A borderless window has to be told it may take key, or the overlay never
/// becomes the active window and the reader is left with a scrim over a
/// transcript that is still taking their keystrokes.
///
/// Escape is **not** handled here — see the note on `MediaOverlayWindow` for why
/// it goes through an event monitor instead.
private final class OverlayPanel: NSWindow {
    override var canBecomeKey: Bool { true }
}

// MARK: -

/// A still of what the source looked like, flying alongside the content.
///
/// Telegram's `oldView.copy()`. A copy is not available here — the source is one
/// tile inside a host's row view, not a view of its own — so the caller hands over
/// its pixels instead, which is the same thing minus the ability to keep
/// animating.
///
/// It draws rather than setting `layer.contents`, because a layer-backed view's
/// backing layer is AppKit's to manage: `contents` set by hand there is liable to
/// be replaced on the next display pass, and `contentsScale` is not maintained for
/// it either. Drawing costs one rasterisation and then the flight scales the
/// bitmap, which is exactly what animating a copied view would have done.
private final class SnapshotView: NSView {

    private let image: NSImage

    init(image: NSImage) {
        self.image = image
        super.init(frame: NSRect(origin: .zero, size: image.size))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SnapshotView is code-only; init(coder:) is unavailable")
    }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds)
    }
}

// MARK: -

/// The dimming, and the region that means "outside".
///
/// `mouseDown` rather than an `NSClickGestureRecognizer`: a recogniser competes
/// with the view's own event handling and only reports on a full click it has
/// decided is not the beginning of something else, where a press on a scrim has
/// nothing to be the beginning of.
private final class MaskView: NSView {

    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
