import SwiftUI

/// Leading status glyph used in the todo popover rows and the chrome
/// button. Three states:
///
///   - `.pending` — hollow ring (Apple Reminders' "unchecked" affordance).
///   - `.inProgress` — hollow ring + concentric inner dot (live verb,
///     still being worked on).
///   - `.completed` — solid-filled ring (the row counts as done; the
///     surrounding row also dims).
///
/// The ring stroke is heavier than a generic Circle().stroke because at
/// small sizes a 1pt line reads as a smudge and fights the row's text
/// weight. 1.4pt is the smallest line width that survives sub-pixel
/// rasterization at 10pt without softening into gray.
struct TodoStatusGlyph: View {

    let status: TodoEntry.Status

    var body: some View {
        Canvas { ctx, size in
            let strokeWidth: CGFloat = 1.4
            let frame = CGRect(origin: .zero, size: size)
                .insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2)
            let ring = Path(ellipseIn: frame)
            switch status {
            case .pending:
                ctx.stroke(ring, with: .color(strokeColor), lineWidth: strokeWidth)
            case .inProgress:
                ctx.stroke(ring, with: .color(strokeColor), lineWidth: strokeWidth)
                let innerInset = size.width * 0.30
                let innerFrame = CGRect(origin: .zero, size: size)
                    .insetBy(dx: innerInset, dy: innerInset)
                ctx.fill(Path(ellipseIn: innerFrame), with: .color(strokeColor))
            case .completed:
                ctx.fill(
                    Path(ellipseIn: CGRect(origin: .zero, size: size)),
                    with: .color(strokeColor.opacity(0.85)))
                // Inner check using two short strokes; cheap to draw
                // and avoids the SF Symbol overlay flicker on dark mode.
                let check = Path { p in
                    let w = size.width
                    let h = size.height
                    p.move(to: CGPoint(x: w * 0.28, y: h * 0.55))
                    p.addLine(to: CGPoint(x: w * 0.45, y: h * 0.70))
                    p.addLine(to: CGPoint(x: w * 0.74, y: h * 0.36))
                }
                ctx.stroke(check, with: .color(.white), lineWidth: strokeWidth)
            }
        }
        .accessibilityHidden(true)
    }

    private var strokeColor: Color {
        switch status {
        case .pending: return Color.secondary
        case .inProgress: return Color.accentColor
        case .completed: return Color.secondary
        }
    }
}
