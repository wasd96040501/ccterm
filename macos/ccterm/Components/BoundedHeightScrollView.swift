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
///
/// Scroll indicators are hidden: the permission card consumers want a
/// clean code/diff block surface without a track painted alongside —
/// scroll wheel / trackpad still scroll, the bar is just invisible.
struct BoundedHeightScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
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

#Preview("long diff scrolls inside the cap") {
    // Real-world shape: a multi-line file edit that exceeds 240pt.
    // The wrapper caps at 240, the diff scrolls inside. Use the
    // preview to confirm there is no scroll bar painted (cards hide
    // indicators) and that wheel/trackpad still scroll the content.
    let oldText = (0..<25).map { i in
        "    case option\(i): return \"option-\(i)\""
    }.joined(separator: "\n")
    let newText = (0..<25).map { i in
        "    case option\(i): return String(localized: \"option-\(i)\")"
    }.joined(separator: "\n")
    return BoundedHeightScrollView(maxHeight: 240) {
        DiffView(
            diff: DiffBlock(
                filePath: "Localized.swift",
                oldString: oldText,
                newString: newText))
    }
    .padding(14)
    .frame(width: 480)
    .background(Color(nsColor: .windowBackgroundColor))
}
