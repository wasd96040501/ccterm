import AppKit

/// A task-list checkbox, drawn rather than typeset.
///
/// Every proportion is Material Design's `mdc-checkbox`, scaled from its 18pt
/// box to whatever the body font asks for — a 1:1 port rather than an
/// approximation, because "looks about right" is how a control ends up subtly
/// wrong at one size and badly wrong at another. From `_checkbox-theme.scss`:
/// `$icon-size: 18px`, `$border-width: 2px`, `$mark-stroke-size: 2/15 × 18`; and
/// `border-radius: 2px` from `_checkbox.scss`. The tick is MDC's own path,
/// `M1.73,12.91 8.1,19.28 22.79,4.59`, stated there over a 24-unit viewBox and
/// normalised here.
///
/// Drawn, not written as `☐` / `☑`, for the reason WebKit draws `list-style:
/// disc` with `fillEllipse` instead of emitting a bullet glyph: a character's
/// size and vertical position ride on whatever font resolves it, and the two
/// ballot-box characters do not even share an advance width — so a list would
/// jitter as its items were ticked. `NativeTranscript2` reached the same
/// conclusion and draws its checkbox as a `CGPath`.
struct Checkbox: Sendable {

    let size: CGFloat
    let checked: Bool
    let fill: NSColor
    let mark: NSColor
    let border: NSColor

    /// The accent, and white on top of it — a filled checkbox is a control, and
    /// a control's tint is the system's to pick.
    static let defaultFill: NSColor = .controlAccentColor
    static let defaultMark: NSColor = .white

    // MARK: - Material's proportions, per unit of box size

    private static let borderWidth: CGFloat = 2 / 18
    private static let cornerRadius: CGFloat = 2 / 18
    private static let markStroke: CGFloat = 2 / 15

    /// `M1.73,12.91 8.1,19.28 22.79,4.59` over a 24-unit viewBox.
    private static let markPath: [CGPoint] = [
        CGPoint(x: 1.73 / 24, y: 12.91 / 24),
        CGPoint(x: 8.1 / 24, y: 19.28 / 24),
        CGPoint(x: 22.79 / 24, y: 4.59 / 24),
    ]

    func items(in rect: CGRect) -> [PaintItem] {
        let radius = size * Self.cornerRadius

        guard checked else {
            // Unchecked: the border only, inset by half its width so the stroke
            // lands inside the box rather than straddling its edge.
            let width = size * Self.borderWidth
            return [
                .stroke(
                    roundedRect: rect.insetBy(dx: width / 2, dy: width / 2),
                    radius: radius, width: width, border, phase: .content)
            ]
        }

        let tick = CGMutablePath()
        let points = Self.markPath.map {
            CGPoint(x: rect.minX + $0.x * size, y: rect.minY + $0.y * size)
        }
        tick.move(to: points[0])
        tick.addLine(to: points[1])
        tick.addLine(to: points[2])

        return [
            .fill(roundedRect: rect, radius: radius, fill, phase: .content),
            // Mitred joins are the context's default, so only the square cap has
            // to be asked for.
            .stroke(tick, width: size * Self.markStroke, cap: .square, mark, phase: .content),
        ]
    }
}
