import SwiftUI

/// 浮在 chat detail 底部 chrome 的统一表面材质 — InputBarView2 / LoadingPillView2
/// 共用。两条分支:
///
/// - macOS 26+:Liquid Glass(`glassEffect(_:in:)`),系统提供半透明 + 边缘高光 +
///   折射;在外面叠一层 `separatorColor` 描边压住边缘,再加柔和阴影。`compositingGroup`
///   保证阴影只投到圆角形状外、不"穿透"玻璃。
/// - macOS 14/15:dark `.thickMaterial` / light `.bar`,clipShape 圆角后描边,
///   light 模式叠一层细阴影增强浮起感。
///
/// 调用方提供 `cornerRadius`,模块内不假设固定值 — InputBar 用 20pt 大圆角,
/// LoadingPill 用更小的 chip-size 圆角(harmonious sub-radius)。
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
    /// 应用 chat detail chrome 的统一表面材质。InputBar / LoadingPill 共享此 modifier
    /// 保证视觉一致 — radius 各传各的。
    func barSurface(cornerRadius: CGFloat) -> some View {
        modifier(BarSurfaceModifier(cornerRadius: cornerRadius))
    }
}
