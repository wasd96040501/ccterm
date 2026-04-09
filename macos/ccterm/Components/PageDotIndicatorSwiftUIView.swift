import SwiftUI

/// SwiftUI page dot indicator, matching the AppKit PageDotIndicatorView style.
struct PageDotIndicatorSwiftUIView: View {
    var count: Int
    @Binding var currentIndex: Int

    private let dotSize: CGFloat = 6
    private let dotSpacing: CGFloat = 8

    var body: some View {
        if count > 1 {
            HStack(spacing: dotSpacing) {
                ForEach(0..<count, id: \.self) { index in
                    Circle()
                        .fill(index == currentIndex ? Color(nsColor: .labelColor) : Color(nsColor: .tertiaryLabelColor))
                        .frame(width: dotSize, height: dotSize)
                        .contentShape(Rectangle().size(width: dotSize + dotSpacing, height: dotSize + 20))
                        .onTapGesture {
                            currentIndex = index
                        }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: currentIndex)
        }
    }
}

#Preview {
    @Previewable @State var index = 0
    PageDotIndicatorSwiftUIView(count: 3, currentIndex: $index)
        .padding()
}
