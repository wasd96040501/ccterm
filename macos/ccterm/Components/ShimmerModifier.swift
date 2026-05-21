import SwiftUI

/// Sweeping-highlight shimmer applied as an alpha mask over the wrapped
/// content. Used by the sidebar history row while `Session.isGeneratingTitle`
/// is true: the LLM-generated title is still being produced, the row already
/// shows the first-message-derived placeholder text, and the shimmer signals
/// that the text is about to change.
///
/// Implementation: a `LinearGradient` mask whose `startPoint` / `endPoint`
/// slide horizontally over time, so the bright band travels across the
/// content. The base alpha (`baseOpacity`) is below 1 to dim the text
/// slightly so the highlight reads as a sweep rather than a flicker.
/// When `active == false` the mask is omitted and the view renders normally.
struct ShimmerModifier: ViewModifier {
    let active: Bool

    /// Full sweep period in seconds — one left-to-right pass.
    static let period: Double = 1.6
    /// Alpha applied to the content when the highlight is not over it.
    static let baseOpacity: Double = 0.55

    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            content.mask(shimmerMask)
        } else {
            content
        }
    }

    private var shimmerMask: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = t.truncatingRemainder(dividingBy: Self.period) / Self.period
            LinearGradient(
                colors: [
                    .white.opacity(Self.baseOpacity),
                    .white,
                    .white.opacity(Self.baseOpacity),
                ],
                startPoint: UnitPoint(x: phase * 2 - 1, y: 0.5),
                endPoint: UnitPoint(x: phase * 2, y: 0.5)
            )
        }
    }
}

extension View {
    /// Apply a sweeping shimmer alpha-mask while `active` is true.
    func shimmer(active: Bool) -> some View {
        modifier(ShimmerModifier(active: active))
    }
}
