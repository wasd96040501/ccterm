import SwiftUI

/// Leading status glyph used in the todo popover rows and the chrome
/// button. Three states, all rendered at the **same outer footprint**
/// so a status flip never shifts the row's leading edge:
///
///   - `.pending` — hollow ring.
///   - `.inProgress` — dotted hollow ring. In the popover it slowly
///     rotates to read as "still working"; in the chrome row it
///     stays static and grey (see `muted`) so the chrome doesn't
///     pull focus away from the transcript.
///   - `.completed` — hollow ring + concentric filled inner dot
///     (Apple Reminders' "marked" affordance), drawn as a single
///     even-odd filled path so the ring band and the inner dot share
///     one rasterizer pass (see `CompletedRingAndDotShape`).
///
/// The ring uses `Circle().strokeBorder(...)` so the stroke stays
/// inside the bounding frame — that's what keeps the outer footprint
/// stable across states.
struct TodoStatusGlyph: View {

    let status: TodoEntry.Status
    /// Quiet variant for the input-bar chrome button: `inProgress`
    /// renders in the same secondary grey as the other states and
    /// skips the rotation animation. The popover keeps the default
    /// (`muted == false`), which is where the live verb belongs.
    var muted: Bool = false

    /// Solid SwiftUI stroke width. 1.4pt is the smallest weight that
    /// survives sub-pixel rasterization at 10–14pt without softening
    /// into gray.
    private static let strokeWidth: CGFloat = 1.4

    var body: some View {
        ZStack {
            switch status {
            case .pending:
                ring
            case .inProgress:
                if muted {
                    // Chrome button stays maximally quiet: the
                    // in-progress glyph is identical to pending —
                    // a plain ring — so the chrome row doesn't
                    // animate or attract focus. The live verb
                    // lives inside the popover.
                    ring
                } else {
                    RotatingDottedRing(strokeWidth: Self.strokeWidth, color: strokeColor)
                }
            case .completed:
                completedRingAndDot
            }
        }
        .accessibilityHidden(true)
    }

    private var ring: some View {
        Circle()
            .strokeBorder(strokeColor, lineWidth: Self.strokeWidth)
    }

    /// Hollow ring + concentric filled dot rendered as a **single**
    /// even-odd filled path: outer disc, ring's inner edge, then the
    /// inner dot. Stroked and filled circles go through separate
    /// rasterizers in SwiftUI and at chrome scale (10pt) the inner
    /// dot rendered visibly darker / denser than the ring's stroke
    /// band. One path, one fill operation = identical antialiasing
    /// for both elements at any size.
    private var completedRingAndDot: some View {
        CompletedRingAndDotShape(strokeWidth: Self.strokeWidth)
            .fill(strokeColor, style: FillStyle(eoFill: true))
    }

    private var strokeColor: Color {
        if muted { return Color.secondary }
        switch status {
        case .pending: return Color.secondary
        case .inProgress: return Color.accentColor
        case .completed: return Color.secondary
        }
    }
}

/// Donut + concentric dot as one path. Even-odd fill rule: outside
/// outer = 0 (skip), ring band = 1 (fill), inner hole = 2 (skip),
/// inner dot = 3 (fill).
private struct CompletedRingAndDotShape: Shape {
    let strokeWidth: CGFloat
    /// Inner dot diameter as a fraction of the outer bounding box —
    /// matches Apple Reminders' generous "marked" affordance.
    private let dotScale: CGFloat = 0.62

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: rect)
        path.addEllipse(in: rect.insetBy(dx: strokeWidth, dy: strokeWidth))
        let dotSize = min(rect.width, rect.height) * dotScale
        let dotRect = CGRect(
            x: rect.midX - dotSize / 2,
            y: rect.midY - dotSize / 2,
            width: dotSize,
            height: dotSize
        )
        path.addEllipse(in: dotRect)
        return path
    }
}

/// Dotted ring that rotates ~one revolution every 6 seconds. Calm
/// enough to read as "still working" without becoming a distraction
/// against text rows. Used only in the popover; the chrome button
/// renders the static `muted` variant instead.
private struct RotatingDottedRing: View {
    let strokeWidth: CGFloat
    let color: Color
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .strokeBorder(
                color,
                style: StrokeStyle(
                    lineWidth: strokeWidth,
                    lineCap: .round,
                    dash: [0, strokeWidth * 2.2]
                )
            )
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}
