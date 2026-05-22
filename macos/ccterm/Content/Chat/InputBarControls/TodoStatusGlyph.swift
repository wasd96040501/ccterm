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
///     (Apple Reminders' "marked" affordance).
///
/// All three are drawn with `Circle().strokeBorder(...)` so the stroke
/// stays inside the bounding frame — that's what keeps the outer
/// footprint stable across states.
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
                ring(style: solidStyle)
            case .inProgress:
                if muted {
                    // Chrome button stays maximally quiet: the
                    // in-progress glyph is identical to pending —
                    // a plain ring — so the chrome row doesn't
                    // animate or attract focus. The live verb
                    // lives inside the popover.
                    ring(style: solidStyle)
                } else {
                    RotatingDottedRing(strokeWidth: Self.strokeWidth, color: strokeColor)
                }
            case .completed:
                ring(style: solidStyle)
                innerDot
            }
        }
        .accessibilityHidden(true)
    }

    // Both shapes take `strokeColor` explicitly. Relying on a single
    // `.foregroundStyle(.secondary)` on the ZStack lets SwiftUI treat
    // the filled inner dot as a lower hierarchy tier than the stroked
    // ring, so the dot rendered visibly lighter than the ring in the
    // chrome glyph — most obvious when every todo is done.
    private func ring(style: StrokeStyle) -> some View {
        Circle()
            .strokeBorder(strokeColor, style: style)
    }

    /// Concentric filled inner circle — matches Apple Reminders'
    /// "completed" affordance: a generous inner dot that nearly fills
    /// the ring, leaving only a thin ring-shaped gap. 0.62 of the
    /// outer box reads as "this is a marked item" at a glance.
    private var innerDot: some View {
        Circle()
            .scale(0.62)
            .fill(strokeColor)
    }

    private var solidStyle: StrokeStyle {
        StrokeStyle(lineWidth: Self.strokeWidth)
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
