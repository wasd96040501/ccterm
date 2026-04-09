import SwiftUI

struct ShakeModifier: ViewModifier {
    var trigger: Bool
    @State private var offset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .onChange(of: trigger) { _ in
                withAnimation(.linear(duration: 0.06)) { offset = -6 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    withAnimation(.linear(duration: 0.06)) { offset = 6 }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    withAnimation(.linear(duration: 0.06)) { offset = -4 }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    withAnimation(.linear(duration: 0.06)) { offset = 4 }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                    withAnimation(.linear(duration: 0.06)) { offset = -2 }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                    withAnimation(.linear(duration: 0.06)) { offset = 0 }
                }
            }
    }
}
