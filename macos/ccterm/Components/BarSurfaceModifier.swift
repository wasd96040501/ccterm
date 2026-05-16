import SwiftUI

/// Unified surface material for chrome floating at the bottom of the chat
/// detail — shared by InputBarView2 / LoadingPillView2. Two branches:
///
/// - macOS 26+: Liquid Glass (`glassEffect(_:in:)`) — system provides
///   translucency + edge highlight + refraction; adds a `separatorColor`
///   stroke to firm up the edge, plus a soft shadow. `compositingGroup`
///   keeps the shadow outside the rounded shape rather than "bleeding"
///   through the glass.
/// - macOS 14/15: dark `.thickMaterial` / light `.bar`, clipped to a
///   rounded rect with a stroke; light mode adds a thin shadow to enhance
///   the lifted feel.
///
/// Caller supplies `cornerRadius`; this modifier doesn't bake in a value —
/// InputBar uses 20pt; LoadingPill uses a smaller chip-size radius
/// (harmonious sub-radius).
///
/// Reference: <https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:isenabled:)>
struct BarSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
                .compositingGroup()
                .shadow(
                    color: .black.opacity(colorScheme == .dark ? 0.3 : 0.12),
                    radius: 12, x: 0, y: 4)
        } else {
            content
                .background(colorScheme == .dark ? .thickMaterial : .bar)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
                .shadow(
                    color: colorScheme == .light ? .black.opacity(0.1) : .clear,
                    radius: 8, x: 0, y: 1)
        }
    }
}

extension View {
    /// Apply the chat-detail chrome surface material. Shared by InputBar /
    /// LoadingPill for visual consistency; each passes its own radius.
    func barSurface(cornerRadius: CGFloat) -> some View {
        modifier(BarSurfaceModifier(cornerRadius: cornerRadius))
    }
}
