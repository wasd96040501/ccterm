import AppKit

/// A task-list checkbox, drawn rather than typeset.
///
/// Every proportion is Chromium's, because GitHub's is. `.markdown-body` gives
/// `.task-list-item-checkbox` no size at all — only `margin: 0 .2em .25em
/// -1.4em` and `vertical-align: middle` — so what a reader sees on github.com is
/// the browser's own `input[type=checkbox]`, and the thing to port is the UA
/// control rather than any stylesheet. The spec is `PaintCheckbox` in
/// `ui/native_theme/native_theme_base.cc`: `kCheckboxSize` 13×13, `kBorderWidth`
/// 1, `GetBorderRadiusForPart(kCheckbox)` 2, and a checkmark of `(0.2, 0.5) →
/// (0.4, 0.7) → (0.8, 0.2)` stroked at `height × 0.16`. A checked box drops its
/// border and fills with the accent instead; both facts are that function's.
///
/// Those numbers are stated against a 13pt box, so each is carried here as a
/// fraction of 13 and multiplied back by whatever `size` is: at 13 this is
/// Chromium pixel for pixel, and at any other size it is the same drawing
/// scaled rather than a nearby different one. Which size to ask for is
/// `ListBuilder`'s call, not this type's.
///
/// A 1:1 port rather than an approximation, because "looks about right" is how a
/// control ends up subtly wrong at one size and badly wrong at another. The
/// previous set of proportions came from Material Design's `mdc-checkbox`, and
/// the two disagree about nearly everything: MDC's border is 2/18 of the box
/// where Chromium's is 1/13, and MDC's tick spans the box corner to corner
/// (`M1.73,12.91 8.1,19.28 22.79,4.59` over 24 units — 0.07 to 0.95) where
/// Chromium's sits inside the middle 60%. Side by side the MDC box reads as
/// heavier and its tick as oversized, which is what a reader comparing against
/// GitHub sees first.
///
/// **Not ported: the background fill.** Chromium fills an unchecked box with the
/// control background before stroking the border; here the border is all that is
/// drawn, so whatever the checkbox sits on shows through. On the transcript's own
/// background the two are the same colour and the difference is invisible; the
/// case where it would not be — a task list inside a tinted row — has no caller,
/// and inventing a background colour this type cannot see the surroundings of is
/// how you get a white patch in dark mode. Add it as a fourth colour parameter
/// the day something renders a list on a tint.
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

    // MARK: - Chromium's proportions, per unit of box size

    /// `kBorderWidth` and `GetBorderRadiusForPart(kCheckbox)` are absolute there
    /// — 1 and 2 — against `kCheckboxSize` 13, so they arrive here as thirteenths.
    private static let borderWidth: CGFloat = 1 / 13
    private static let cornerRadius: CGFloat = 2 / 13
    /// `flags.setStrokeWidth(skrect.height() * 0.16f)`, already a fraction.
    private static let markStroke: CGFloat = 0.16

    /// `moveTo(x + w×0.2, centerY)`, `rLineTo(w×0.2, h×0.2)`,
    /// `lineTo(right − w×0.2, y + h×0.2)` — y-down, which is `BlockView`'s
    /// direction as well as Skia's, so the points transfer unchanged.
    private static let markPath: [CGPoint] = [
        CGPoint(x: 0.2, y: 0.5),
        CGPoint(x: 0.4, y: 0.7),
        CGPoint(x: 0.8, y: 0.2),
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
            // No border under it: a checked box is the accent, edge to edge.
            .fill(roundedRect: rect, radius: radius, fill, phase: .content),
            // Butt cap and mitred join are both Skia's defaults, which `PaintItem`
            // and `CGContext` share — so the port asks for neither.
            .stroke(tick, width: size * Self.markStroke, mark, phase: .content),
        ]
    }
}
