import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Mount the real `BoundedHeightScrollView` in an `NSHostingView` and
/// assert on the actual rendered height. Covers the two branches the
/// permission cards depend on:
///
/// - Content intrinsic height < `maxHeight` → wrapper sizes to the
///   intrinsic content (no wasted vertical space under the buttons).
///   `ViewThatFits` picks the first (intrinsic) child.
/// - Content intrinsic height > `maxHeight` → `ViewThatFits` falls
///   back to the `ScrollView` branch and the wrapper caps at the
///   max; the inner scroll view's scroller appears so the user can
///   reach lines that would otherwise push the buttons off-screen.
///
/// The fixture sizes the host to a generous outer rect so the parent
/// proposes ≥ `maxHeight` vertically — the `.frame(maxHeight:)`
/// inside the wrapper then provides ViewThatFits the bounded
/// available space it needs to compare against. Under XCTest's
/// offscreen runloop, `NSHostingView.frame.height` reflects the
/// resolved layout once `layoutSubtreeIfNeeded()` settles.
@MainActor
final class BoundedHeightScrollViewTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testShortContentSizesToIntrinsicHeight() {
        // Three monospaced lines at 12pt with 4pt spacing run to
        // ~52pt total — well under the 240pt cap. ViewThatFits's
        // first branch (intrinsic) fits, so the wrapper should size
        // to the intrinsic content (no 240pt floor).
        let height = renderedHostHeight(
            content: { ShortFixtureContent() },
            cap: 240,
            width: 380)

        XCTAssertGreaterThan(height, 0)
        XCTAssertLessThan(
            height, 240,
            "short content should size to intrinsic, got \(height)")
        XCTAssertGreaterThanOrEqual(
            height, 30,
            "short content should still have at least intrinsic line height")
    }

    func testTallContentCapsAtMaxHeight() {
        // 80 lines at 12pt with 4pt spacing greatly exceeds 240pt.
        // ViewThatFits's first branch doesn't fit, so it falls back
        // to the ScrollView branch. The wrapper caps at exactly 240
        // (allow 1pt for rounding).
        let height = renderedHostHeight(
            content: { TallFixtureContent() },
            cap: 240,
            width: 380)

        XCTAssertEqual(
            height, 240, accuracy: 1.0,
            "tall content should cap at the maxHeight, got \(height)")
    }

    func testTallContentMountsAnNSScrollView() {
        // The fallback branch must really be a scrollable container,
        // not a clipped frame — verify by walking the bridged AppKit
        // tree for an `NSScrollView` once the wrapper has capped at
        // `maxHeight`.
        let host = mountedHost(
            content: { TallFixtureContent() }, cap: 240, width: 380)
        defer { host.window?.close() }

        XCTAssertNotNil(
            findScrollView(in: host),
            "tall content should mount inside an NSScrollView fallback")
    }

    func testShortContentSkipsTheScrollView() {
        // Inverse of the above: when content fits, `ViewThatFits`
        // picks the intrinsic branch — no scroll chrome around the
        // user's content.
        let host = mountedHost(
            content: { ShortFixtureContent() }, cap: 240, width: 380)
        defer { host.window?.close() }

        XCTAssertNil(
            findScrollView(in: host),
            "short content should bypass the scroll fallback")
    }

    // MARK: - Mounting helpers

    private func mountedHost<Content: View>(
        @ViewBuilder content: () -> Content,
        cap: CGFloat,
        width: CGFloat
    ) -> NSHostingView<some View> {
        let root = HostFixture(maxHeight: cap, width: width, content: content())
        let host = NSHostingView(rootView: root)
        let containerSize = CGSize(width: width + 40, height: max(cap * 4, 800))
        host.frame = CGRect(origin: .zero, size: containerSize)
        let window = NSWindow(
            contentRect: CGRect(
                origin: CGPoint(x: -30_000, y: -30_000),
                size: containerSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.alphaValue = 0.01
        window.contentView = host
        window.ccterm_orderFrontForTesting()
        host.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            RunLoop.main.run(
                mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            host.layoutSubtreeIfNeeded()
        }
        return host
    }

    private func renderedHostHeight<Content: View>(
        @ViewBuilder content: () -> Content,
        cap: CGFloat,
        width: CGFloat
    ) -> CGFloat {
        let host = mountedHost(content: content, cap: cap, width: width)
        defer { host.window?.close() }
        // The fixture pins width and lets vertical sizing fall out of
        // the wrapper. `NSHostingView.frame` reflects the SwiftUI
        // tree's resolved size once `layoutSubtreeIfNeeded()`
        // settles.
        return host.frame.height
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews {
            if let hit = findScrollView(in: sub) { return hit }
        }
        return nil
    }
}

/// Hosts the wrapper at a fixed width with vertical sizing pinned to
/// the SwiftUI content. `fixedSize(vertical: true)` makes the host
/// view's frame collapse to the wrapper's resolved height instead of
/// padding out to the window's contentRect.
private struct HostFixture<Content: View>: View {
    let maxHeight: CGFloat
    let width: CGFloat
    let content: Content

    var body: some View {
        BoundedHeightScrollView(maxHeight: maxHeight) {
            content
        }
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Three monospaced lines — well under the 240pt cap used in the
/// tests. Intrinsic height is roughly `3 * lineHeight + 2 * 4pt ≈ 52pt`.
private struct ShortFixtureContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<3) { i in
                Text("line \(i)")
                    .font(.system(size: 12, design: .monospaced))
            }
        }
    }
}

/// 80 monospaced lines — well over the 240pt cap. Intrinsic height is
/// roughly `80 * lineHeight + 79 * 4pt ≈ 1500pt`.
private struct TallFixtureContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<80) { i in
                Text("line \(i)")
                    .font(.system(size: 12, design: .monospaced))
            }
        }
    }
}
