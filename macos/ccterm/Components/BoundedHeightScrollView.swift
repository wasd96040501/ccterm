import SwiftUI

/// Vertical scroll container that sizes to its content's intrinsic
/// height when the content fits in `maxHeight`, and caps + scrolls
/// once the content exceeds the cap. Mirrors the "use intrinsic when
/// small, scroll when large" pattern the permission card bodies want
/// for the `DiffView`/monospace blocks they embed.
///
/// Implementation: `.fixedSize(horizontal: false, vertical: true)`
/// tells SwiftUI to use the `ScrollView`'s ideal vertical size —
/// which is the content's natural height — instead of the parent's
/// vertical proposal. `.frame(maxHeight:)` then clamps that ideal
/// height. The resolved size is therefore
/// `min(content.idealHeight, maxHeight)`: synchronous, no preference
/// round-trip, no `@State`.
///
/// Works through an `NSViewRepresentable` child because SwiftUI
/// consults the bridge's `sizeThatFits(_:nsView:context:)` for its
/// ideal vertical size — `DiffView` returns its real height from
/// that hook.
struct BoundedHeightScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.vertical) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview("short content fits without scroll") {
    BoundedHeightScrollView(maxHeight: 240) {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<3) { i in
                Text("Line \(i)")
                    .font(.system(size: 12, design: .monospaced))
            }
        }
    }
    .padding(14)
    .frame(width: 420)
    .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("tall content caps and scrolls") {
    BoundedHeightScrollView(maxHeight: 240) {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<80) { i in
                Text("Line \(i)")
                    .font(.system(size: 12, design: .monospaced))
            }
        }
    }
    .padding(14)
    .frame(width: 420)
    .background(Color(nsColor: .windowBackgroundColor))
}
