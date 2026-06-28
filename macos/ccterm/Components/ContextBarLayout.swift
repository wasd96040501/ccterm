import AgentSDK
import CoreGraphics
import Foundation

/// SwiftUI-free layout math for the context-usage breakdown bar
/// (migration plan §4.2). Lifted verbatim out of the private
/// `ContextBreakdownView` in `ContextRingButton.swift` so **two** renderers
/// can share one source of truth: the still-present SwiftUI popover
/// (`ContextBreakdownView` / `CategoryRow`) and the new AppKit
/// `ContextBarView` (custom `draw(_:)`).
///
/// What lives here (the genuine, testable math — no `View`, no `NSColor`,
/// no `Color`):
///
///   - `ordered(_:)` — the display order: active rows by tokens desc, then
///     deferred rows by tokens desc, then the buffer row, then Free space
///     (mirrors the JS reference).
///   - `displaySum(_:)` — the segment-width denominator: `max(1, Σ tokens)`
///     over **every** visible category so the bar always fills the width.
///   - `rankInActive(ordered:at:)` — how many active (non-deferred /
///     non-buffer / non-free) entries come at or before an index; drives the
///     accent color-step.
///   - `segmentKind(for:rankInActive:)` — the appearance-agnostic color
///     *intent* (`.free` / `.muted` / `.active(opacity:)`), resolved to a
///     concrete `Color` (SwiftUI) or `NSColor` (AppKit) by each renderer.
///   - `segments(for:)` — the laid-out bar segments (proportion + color
///     kind), with the same `< 0.5%` sliver skip the SwiftUI `barTrack` used.
///
/// Color *values* are NOT here: SwiftUI resolves a `SegmentKind` →
/// `Color(nsColor: …).opacity(…)` and AppKit resolves it → semantic
/// `NSColor` in `draw(_:)` (re-resolving per draw on appearance flip, plan
/// §4.2-3). Keeping the *kind* shared means the ordering/step/sliver math is
/// tested once and rendered identically by both.
enum ContextBarLayout {

    // MARK: - Color intent (appearance- / framework-agnostic)

    /// The color *intent* for one category / bar segment, resolved to a
    /// concrete `Color`/`NSColor` by the renderer. Mirrors the three arms of
    /// the original `ContextBreakdownView.color(for:rankInActive:)`:
    ///
    ///   - `.free` — "Free space": `quaternaryLabelColor` @ 0.4 opacity.
    ///   - `.muted` — deferred rows + the autocompact/compact buffer:
    ///     `quaternaryLabelColor` (full opacity).
    ///   - `.active(opacity:)` — active rows: `accentColor` stepped down from
    ///     full toward a pale tint as `rankInActive` grows, clamped at 6 steps
    ///     and a 0.35 opacity floor.
    enum SegmentKind: Equatable {
        case free
        case muted
        case active(opacity: Double)
    }

    /// One laid-out bar segment: a width `proportion` of the track (0...1) and
    /// the color `kind` to fill it with. Segments narrower than 0.5% are
    /// dropped before this list is built (the SwiftUI `barTrack` sliver skip).
    struct Segment: Equatable {
        let proportion: Double
        let kind: SegmentKind
    }

    // MARK: - Sliver threshold (ContextRingButton.swift barTrack)

    /// Bar segments narrower than this fraction of the track are skipped — the
    /// SwiftUI `barTrack` did `if proportion >= 0.005` (skip slivers < 0.5%).
    static let sliverThreshold: Double = 0.005

    /// Accent color-step: each active rank past 0 drops opacity by this much.
    static let activeOpacityStep: Double = 0.12

    /// Number of distinct accent steps before they stop differing (cap so very
    /// long active lists still render).
    static let activeStepCap: Int = 6

    /// Opacity floor for the palest active segment.
    static let activeOpacityFloor: Double = 0.35

    // MARK: - Buffer / free naming (ContextRingButton.swift isBufferName)

    /// The two CLI category names that render as the uniform-gray "buffer"
    /// segment (`ContextRingButton.swift:270-272`).
    static func isBufferName(_ name: String) -> Bool {
        name == "Autocompact buffer" || name == "Compact buffer"
    }

    /// The CLI category name for the trailing "unused window" segment.
    static let freeSpaceName = "Free space"

    /// True when a category is one of the active (accent-stepped) rows —
    /// i.e. NOT deferred, NOT the buffer, NOT free space.
    static func isActive(_ cat: ContextUsage.Category) -> Bool {
        !cat.isDeferred && cat.name != freeSpaceName && !isBufferName(cat.name)
    }

    // MARK: - Ordering (ContextBreakdownView.ordered)

    /// Display order: active rows by tokens desc, then deferred rows by tokens
    /// desc, then the buffer row (if any), then Free space (if any). Ported
    /// verbatim from `ContextBreakdownView.ordered`.
    static func ordered(_ usage: ContextUsage) -> [ContextUsage.Category] {
        let buffer = usage.categories.first { isBufferName($0.name) }
        let free = usage.categories.first { $0.name == freeSpaceName }
        let active =
            usage.categories
            .filter { isActive($0) }
            .sorted { $0.tokens > $1.tokens }
        let deferred =
            usage.categories
            .filter { $0.isDeferred }
            .sorted { $0.tokens > $1.tokens }
        return active + deferred + (buffer.map { [$0] } ?? []) + (free.map { [$0] } ?? [])
    }

    // MARK: - Segment-width denominator (ContextBreakdownView.displaySum)

    /// Sum used for bar segment widths. Includes every visible category
    /// (active + deferred + buffer + free) so the bar always fills the full
    /// width. `max(1, …)` so a zero-token usage divides safely.
    static func displaySum(_ ordered: [ContextUsage.Category]) -> Int {
        max(1, ordered.reduce(0) { $0 + $1.tokens })
    }

    // MARK: - Active rank (ContextBreakdownView.rankInActive)

    /// How many active (non-deferred / non-buffer / non-free) entries come at
    /// or before `index` in the `ordered` list. Used to color-step the active
    /// segments while keeping deferred + buffer + free uniformly gray. Ported
    /// verbatim from `ContextBreakdownView.rankInActive(at:)`.
    ///
    /// Returns 0 for an out-of-range index (defensive; the original indexed
    /// `ordered` directly).
    static func rankInActive(ordered: [ContextUsage.Category], at index: Int) -> Int {
        guard index >= 0, index < ordered.count else { return 0 }
        var rank = 0
        for i in 0...index {
            let cat = ordered[i]
            if isActive(cat) {
                if i == index { return rank }
                rank += 1
            }
        }
        return rank
    }

    // MARK: - Color intent (ContextBreakdownView.color)

    /// The color *intent* for a category at a given active rank. Ported
    /// verbatim from `ContextBreakdownView.color(for:rankInActive:)`, minus the
    /// `Color` construction (left to the renderer):
    ///
    ///   - Free space → `.free`
    ///   - deferred / buffer → `.muted`
    ///   - active → `.active(opacity:)`, stepping `1.0 - step * 0.12` clamped at
    ///     6 steps and floored at 0.35.
    static func segmentKind(for cat: ContextUsage.Category, rankInActive: Int) -> SegmentKind {
        if cat.name == freeSpaceName {
            return .free
        }
        if cat.isDeferred || isBufferName(cat.name) {
            return .muted
        }
        let step = min(rankInActive, activeStepCap)
        let opacity = 1.0 - Double(step) * activeOpacityStep
        return .active(opacity: max(activeOpacityFloor, opacity))
    }

    // MARK: - Laid-out bar segments (ContextBreakdownView.barTrack)

    /// The bar's segments in display order: each visible category's width
    /// `proportion` (its tokens / `displaySum`) paired with its color `kind`.
    /// Segments narrower than `sliverThreshold` (0.5%) are dropped — exactly
    /// the SwiftUI `barTrack`'s `if proportion >= 0.005` skip.
    ///
    /// The proportions of the kept segments do **not** re-normalize to 1.0
    /// (matching SwiftUI: dropped slivers leave a hair of the rounded track
    /// background showing), so a renderer lays each segment at
    /// `trackWidth * proportion` left-to-right.
    static func segments(for usage: ContextUsage) -> [Segment] {
        let ordered = ordered(usage)
        let sum = Double(displaySum(ordered))
        var result: [Segment] = []
        result.reserveCapacity(ordered.count)
        for (idx, cat) in ordered.enumerated() {
            let proportion = Double(cat.tokens) / sum
            guard proportion >= sliverThreshold else { continue }
            let kind = segmentKind(for: cat, rankInActive: rankInActive(ordered: ordered, at: idx))
            result.append(Segment(proportion: proportion, kind: kind))
        }
        return result
    }
}
