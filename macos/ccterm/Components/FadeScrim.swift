import SwiftUI

/// One-axis fade scrim. Opaque at one edge, transparent at the other —
/// drop it as an overlay over the leading or trailing edge of a scroll
/// region so content fades into the surrounding chrome instead of
/// cutting off at a hard line.
///
/// Used in two flavors:
///
/// - **Top of a transcript / list** — `.topToBottom`, fades the row that
///   would otherwise butt up against the window's top edge.
/// - **Bottom of a transcript** — `.bottomToTop`, fades the last visible
///   row so it dissolves into the chrome under the input bar rather than
///   being clipped by the bar. (The chat transcript's own top/bottom
///   fades are now the AppKit `TranscriptTopScrimView` /
///   `TranscriptBottomScrimView` on `ChatSessionViewController`; this
///   SwiftUI scrim is used for the New Session card's recents list.)
///
/// Generic over `ShapeStyle` so callers can fade to whatever underlies
/// the scroll region — `Color(nsColor: .windowBackgroundColor)` over the
/// window itself (default; light/dark aware), or `.ultraThinMaterial`
/// over a material-backed pane so the opaque end stacks with the
/// surface beneath instead of reading as a mismatched flat fill. The
/// fade is realized by masking a `Rectangle().fill(style)` with a
/// `LinearGradient`, which works uniformly for both colors and
/// materials.
struct FadeScrim<S: ShapeStyle>: View {
    enum Direction {
        case topToBottom
        case bottomToTop
    }

    let direction: Direction
    let height: CGFloat
    let style: S

    init(_ direction: Direction, height: CGFloat, style: S) {
        self.direction = direction
        self.height = height
        self.style = style
    }

    var body: some View {
        Rectangle()
            .fill(style)
            .mask {
                LinearGradient(
                    colors: [.black, .clear],
                    startPoint: direction == .topToBottom ? .top : .bottom,
                    endPoint: direction == .topToBottom ? .bottom : .top
                )
            }
            .frame(height: height)
            .allowsHitTesting(false)
    }
}

extension FadeScrim where S == Color {
    /// Convenience: default to `windowBackgroundColor` (NS-managed, so
    /// it tracks the system appearance automatically). For a fade laid
    /// directly over the window background.
    init(_ direction: Direction, height: CGFloat) {
        self.init(direction, height: height, style: Color(nsColor: .windowBackgroundColor))
    }
}
