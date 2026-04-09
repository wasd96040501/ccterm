import SwiftUI

// MARK: - ButtonStyle

struct HoverCapsuleStyle: ButtonStyle {
    var hoverColor: Color = Color(nsColor: .labelColor)
    var hoverOpacity: Double = 0.08
    var pressOpacity: Double = 0.15
    /// When set, the capsule background is always visible with this color (hover still darkens).
    var staticFill: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(HoverCapsuleModifier(
                hoverColor: hoverColor,
                hoverOpacity: hoverOpacity,
                pressOpacity: pressOpacity,
                staticFill: staticFill,
                isPressed: configuration.isPressed
            ))
    }
}

// MARK: - ViewModifier (shared implementation)

struct HoverCapsuleModifier: ViewModifier {
    var hoverColor: Color = Color(nsColor: .labelColor)
    var hoverOpacity: Double = 0.08
    var pressOpacity: Double = 0.15
    var staticFill: Color? = nil
    var isPressed: Bool = false

    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(backgroundFill)
            )
            .onHover { isHovered = $0 }
    }

    private var backgroundFill: Color {
        if let fill = staticFill {
            if isPressed { return fill.opacity(0.8) }
            if isHovered { return fill.opacity(0.8) }
            return fill
        }
        return hoverColor.opacity(
            isPressed ? pressOpacity : (isHovered ? hoverOpacity : 0)
        )
    }
}

// MARK: - View Extension

extension View {
    /// Apply a capsule background. When `staticFill` is set, always visible; otherwise hover-only.
    func hoverCapsule(
        staticFill: Color? = nil,
        hoverColor: Color = Color(nsColor: .labelColor),
        hoverOpacity: Double = 0.08
    ) -> some View {
        modifier(HoverCapsuleModifier(
            hoverColor: hoverColor,
            hoverOpacity: hoverOpacity,
            staticFill: staticFill
        ))
    }
}
