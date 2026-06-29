import AgentSDK
import AppKit

/// AppKit replacement for the SwiftUI context-usage **bar track** — the
/// thin segmented bar at the top of the `ContextBreakdownView` popover
/// (`ContextRingButton.swift` `barTrack`; migration plan §4.2, §5). A
/// custom-`draw(_:)` `NSView` that paints, left-to-right:
///
///   1. a rounded-rect **track background** (`quaternaryLabelColor` @ 0.6
///      opacity, corner radius 2), then
///   2. each visible category **segment** at width `trackWidth * proportion`,
///      filled with the segment's resolved color, the whole row clipped to the
///      same rounded-rect (the SwiftUI `.clipShape(RoundedRectangle(2))`).
///
/// The ordering / `displaySum` / `rankInActive` / color-step / `< 0.5%` sliver
/// math is **not** here — it lives in the SwiftUI-free `ContextBarLayout`, so
/// the still-present SwiftUI popover (`ContextBreakdownView`) and this view
/// render the identical layout from one tested source of truth. This view only
/// turns `ContextBarLayout.Segment`s into pixels.
///
/// ## Semantic color in `draw(_:)`, NOT cgColor-on-layer
///
/// Per plan §4.2-3 / §4.2: the segment + track colors are **semantic
/// `NSColor`** (`controlAccentColor`, `quaternaryLabelColor`) applied inside
/// `draw(_:)`. AppKit installs the view's `effectiveAppearance` as the current
/// drawing appearance for the duration of `draw(_:)`, so each `.setFill()`
/// re-resolves against the live appearance every draw — there is no frozen
/// `CALayer.cgColor` to re-resolve on a dark/light flip (the R14 hazard the
/// layer-backed `ProgressRingView` had to guard). The colors re-resolve for
/// free, but a *redraw still has to be scheduled* on an appearance flip, which
/// is exactly what the explicit `viewDidChangeEffectiveAppearance` override
/// does — it is the load-bearing repaint trigger, not redundant.
///
/// ## Empty placeholder
///
/// With no `usage` (the popover's fetching / no-CLI state), the view paints
/// **only** the rounded track background and no segments — a flat 0%-track,
/// matching the bar's appearance before any breakdown lands.
final class ContextBarView: NSView {

    // MARK: - Constants (verbatim from ContextRingButton.swift barTrack)

    /// The bar's fixed height (`barTrack` `.frame(height: 6)`).
    static let barHeight: CGFloat = 6

    /// The rounded-rect corner radius for the clip + track background
    /// (`RoundedRectangle(cornerRadius: 2, style: .continuous)`).
    static let cornerRadius: CGFloat = 2

    /// Opacity applied to `quaternaryLabelColor` for the track background
    /// (`barTrack` `.background { … .opacity(0.6) }`).
    static let trackBackgroundOpacity: CGFloat = 0.6

    // MARK: - Public

    /// The breakdown to render. `nil` paints only the track (the
    /// fetching / no-CLI placeholder). Setting it recomputes the laid-out
    /// segments via `ContextBarLayout.segments(for:)` and redraws.
    var usage: ContextUsage? {
        didSet {
            recomputeSegments()
            needsDisplay = true
        }
    }

    // MARK: - Cached layout

    /// The laid-out segments from `ContextBarLayout`. Recomputed only when
    /// `usage` changes, never inside `draw(_:)` (no per-frame allocation).
    private var segments: [ContextBarLayout.Segment] = []

    // MARK: - Init

    init(usage: ContextUsage? = nil) {
        self.usage = usage
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: ContextBarView.barHeight))
        translatesAutoresizingMaskIntoConstraints = false
        recomputeSegments()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// macOS 26 SDK workaround: an empty `nonisolated deinit` so the
    /// `@MainActor` deinit executor hop doesn't abort under
    /// `libswift_Concurrency` (mirrors the other Phase-0 leaves).
    nonisolated deinit {}

    // MARK: - Sizing

    /// Publish a fixed height (6) and **no** intrinsic width — the bar fills
    /// whatever width its container gives it (the popover's content width),
    /// matching the SwiftUI `GeometryReader`-driven full-width fill. Width
    /// `noIntrinsicMetric` keeps the view from leaking a width up into a host's
    /// `fittingSize`.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.barHeight)
    }

    override var isFlipped: Bool { true }

    // MARK: - Resolved segment geometry (the single source draw(_:) consumes)

    /// The laid-out segments the view will draw (post-sliver-skip), in display
    /// order. Mirrors `ContextBarLayout.segments(for: usage)`. Read by the
    /// CI-gate `ContextBarLayoutTests`; also the input to `resolvedSegmentRects`.
    var resolvedSegments: [ContextBarLayout.Segment] { segments }

    /// The track-local pixel frame each segment occupies for a given track
    /// width, in display order — `x` accumulates left-to-right at
    /// `width * proportion`. **This is the one place that sweep lives:**
    /// `draw(_:)` consumes these rects (offsetting `y` by the centered
    /// `trackY`) so a regression in the accumulation / width math is painted
    /// AND observed by the test through the same code path. `y` is `0` here
    /// (track-local); `draw(_:)` adds `trackY`.
    func resolvedSegmentRects(forWidth width: CGFloat) -> [CGRect] {
        var rects: [CGRect] = []
        rects.reserveCapacity(segments.count)
        var x: CGFloat = 0
        for seg in segments {
            let w = width * CGFloat(seg.proportion)
            rects.append(CGRect(x: x, y: 0, width: w, height: Self.barHeight))
            x += w
        }
        return rects
    }

    // MARK: - Layout cache

    private func recomputeSegments() {
        segments = usage.map { ContextBarLayout.segments(for: $0) } ?? []
    }

    // MARK: - Appearance

    /// Semantic colors re-resolve inside `draw(_:)` automatically, but a
    /// redraw must be **scheduled** on an appearance flip so the new resolution
    /// is actually painted (plan §4.2-3). For a `draw(_:)`-only view that has
    /// nothing observing the appearance, this override is the load-bearing
    /// trigger that repaints already-drawn content on a dark/light switch.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Draw

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // The track is vertically centered within the view's bounds at the
        // fixed bar height (so a taller frame doesn't stretch the 6pt bar).
        let trackHeight = Self.barHeight
        let trackY = (bounds.height - trackHeight) / 2
        let trackRect = CGRect(x: 0, y: trackY, width: bounds.width, height: trackHeight)
        guard trackRect.width > 0 else { return }

        let clipPath = BarSurfaceGeometry.continuousRoundedPath(
            in: trackRect, cornerRadius: Self.cornerRadius)

        // 1. Track background — quaternaryLabelColor @ 0.6, clipped rounded.
        //    Semantic NSColor: re-resolves against the current drawing
        //    appearance every draw, so no frozen cgColor to flip.
        context.saveGState()
        context.addPath(clipPath)
        context.clip()
        NSColor.quaternaryLabelColor.withAlphaComponent(Self.trackBackgroundOpacity).setFill()
        context.fill(trackRect)

        // 2. Segments left-to-right within the same rounded clip, consuming
        //    the single segment-rect sweep `resolvedSegmentRects` owns (the
        //    same geometry the CI-gate test asserts on). Offset each
        //    track-local rect's `y` by the centered `trackY`; skip zero-width
        //    fills (slivers are already dropped upstream, so this only bites a
        //    zero-width track).
        for (rect, seg) in zip(resolvedSegmentRects(forWidth: trackRect.width), segments) {
            guard rect.width > 0 else { continue }
            let segRect = rect.offsetBy(dx: 0, dy: trackY)
            Self.color(for: seg.kind).setFill()
            context.fill(segRect)
        }
        context.restoreGState()
    }

    // MARK: - Color resolution (kind → semantic NSColor)

    /// Resolve a `ContextBarLayout.SegmentKind` color *intent* to a concrete
    /// **semantic** `NSColor`, mirroring the SwiftUI popover's
    /// `ContextBreakdownView.color(for:rankInActive:)` arms one-for-one:
    ///
    ///   - `.free` → `quaternaryLabelColor` @ 0.4
    ///   - `.muted` → `quaternaryLabelColor` (full)
    ///   - `.active(opacity:)` → `controlAccentColor` @ opacity (the AppKit
    ///     analogue of SwiftUI `Color.accentColor`).
    ///
    /// Returned semantic colors re-resolve per draw against the live
    /// appearance / accent — no cgColor freeze (plan §4.2-3).
    static func color(for kind: ContextBarLayout.SegmentKind) -> NSColor {
        switch kind {
        case .free:
            return NSColor.quaternaryLabelColor.withAlphaComponent(0.4)
        case .muted:
            return NSColor.quaternaryLabelColor
        case .active(let opacity):
            return NSColor.controlAccentColor.withAlphaComponent(CGFloat(opacity))
        }
    }
}
