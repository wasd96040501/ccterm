import SwiftUI

/// Overlay-based tooltip that appears on hover without intercepting clicks.
/// Automatically positions above or below based on available space.
struct HoverTooltip: ViewModifier {
    let text: String
    @State private var isHovering = false
    @State private var showAbove = true

    func body(content: Content) -> some View {
        content
            .onHover { isHovering = $0 }
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onChange(of: isHovering) { _, hovering in
                            if hovering {
                                let frameInWindow = geo.frame(in: .global)
                                showAbove = frameInWindow.minY > 40
                            }
                        }
                }
            }
            .overlay(alignment: showAbove ? .top : .bottom) {
                if isHovering {
                    Text(text)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        }
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                        .fixedSize()
                        .offset(y: showAbove ? -32 : 32)
                        .allowsHitTesting(false)
                        .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                }
            }
    }
}

extension View {
    func hoverTooltip(_ text: String) -> some View {
        modifier(HoverTooltip(text: text))
    }
}
