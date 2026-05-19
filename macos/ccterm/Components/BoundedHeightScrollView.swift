import SwiftUI

/// Vertical scroll container that grows to its content's intrinsic
/// height when the content fits in `maxHeight`, and caps + scrolls
/// once the content exceeds the cap. Mirrors the "use intrinsic when
/// small, scroll when large" pattern the permission card bodies want
/// for the `DiffView`/monospace blocks they embed.
///
/// Implementation uses `ViewThatFits`: SwiftUI tries the intrinsic
/// content first, and if it doesn't fit in the available vertical
/// space, falls back to a `ScrollView` capped at `maxHeight`. The
/// surrounding `.frame(maxHeight:)` provides the bounded available
/// space ViewThatFits needs to compare against.
///
/// **NSViewRepresentable caveat.** `ViewThatFits` poses an
/// "unspecified" proposal to size-check the intrinsic branch. An
/// `NSViewRepresentable` whose `sizeThatFits` returns `nil` for an
/// unspecified proposal (e.g. `DiffView`, which requires a finite
/// width) reads as "no opinion" and ViewThatFits falls through to
/// the scroll branch. In practice that means a `DiffView` child
/// always renders inside the scroll fallback (cap height with the
/// diff at the top); the intrinsic-shrink optimisation only fires
/// for native SwiftUI content (`Text`, stacks). Acceptable trade-off
/// — the cap-always behaviour matches the previous
/// `ScrollView { ... }.frame(maxHeight:)` pattern these cards used,
/// and the buttons stay reachable in either branch.
///
/// `content()` is referenced twice in source (once intrinsic, once
/// inside the scroll fallback) but `ViewThatFits` only mounts the
/// chosen branch — important for the `DiffView` consumer where a
/// duplicate mount would re-run the async syntax-highlight pass.
struct BoundedHeightScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            // `fixedSize(vertical: true)` helps SwiftUI-native
            // children (Text stacks, etc.) publish a concrete
            // vertical size to ViewThatFits; without it some
            // children defer their height and the scroll fallback
            // gets picked unnecessarily. See the type-level docs
            // for the `NSViewRepresentable` caveat — that branch
            // doesn't go through this seam and always lands in the
            // scroll fallback.
            content()
                .fixedSize(horizontal: false, vertical: true)
            ScrollView(.vertical, showsIndicators: true) {
                content()
            }
        }
        .frame(maxHeight: maxHeight)
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
