import SwiftUI

/// Static, ultra-faint dot-grid texture. Use as a backdrop layer
/// (typically over `VisualEffectView`) so a large empty region — e.g.
/// the area around the New Session compose card — has a hint of
/// structure instead of reading as a dead flat fill, without ever
/// drawing attention to itself.
///
/// Tuned to sit at the edge of perception: 24pt pitch, 1pt circles,
/// ~4% label-color opacity. Light/dark aware via `Color.primary`.
/// No motion, no animation — a controlled, restrained texture, not a
/// decoration.
struct DotGridBackground: View {
    var pitch: CGFloat = 24
    var dotDiameter: CGFloat = 1
    var opacity: Double = 0.045

    var body: some View {
        Canvas { context, size in
            let radius = dotDiameter / 2
            let color = Color.primary.opacity(opacity)
            var y: CGFloat = pitch / 2
            while y < size.height {
                var x: CGFloat = pitch / 2
                while x < size.width {
                    let rect = CGRect(
                        x: x - radius,
                        y: y - radius,
                        width: dotDiameter,
                        height: dotDiameter
                    )
                    context.fill(Path(ellipseIn: rect), with: .color(color))
                    x += pitch
                }
                y += pitch
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
