import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Mount the real `BoundedHeightScrollView` in an offscreen window
/// (same posture as `ViewSnapshot.render`), run one layout pass, then
/// walk the bridged NSView tree to read the inner `NSScrollView`'s
/// resolved frame. That frame is what `.frame(maxHeight:) +
/// .fixedSize(...)` on the wrapper resolved to — the same height the
/// user sees on screen.
///
/// With the `fixedSize + maxHeight` implementation, the wrapper's size
/// resolves synchronously during the first layout pass (no preference
/// round-trip), so a single `layoutSubtreeIfNeeded()` plus a short
/// runloop drain — long enough for an `NSViewRepresentable` child
/// (e.g. `DiffView`) to settle its `sizeThatFits` — is all the test
/// needs.
@MainActor
final class BoundedHeightScrollViewTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Native SwiftUI content

    func testShortContentSizesToIntrinsicHeight() {
        // Three monospaced lines at 12pt with 4pt spacing run to
        // ~52pt total — well under the 240pt cap. The wrapper should
        // shrink to that intrinsic height, not stay padded out to 240.
        let height = resolvedWrapperHeight(
            content: { ShortFixtureContent() },
            cap: 240,
            width: 380)

        XCTAssertGreaterThan(height, 0)
        XCTAssertLessThan(
            height, 240,
            "short content should size to intrinsic, got \(height)")
        XCTAssertGreaterThanOrEqual(
            height, 30,
            "short content should still cover at least one line of intrinsic height")
    }

    func testTallContentCapsAtMaxHeight() {
        // 80 lines at 12pt with 4pt spacing greatly exceeds 240pt.
        // The wrapper should cap at exactly 240 (allow 1pt rounding).
        let height = resolvedWrapperHeight(
            content: { TallFixtureContent() },
            cap: 240,
            width: 380)

        XCTAssertEqual(
            height, 240, accuracy: 1.0,
            "tall content should cap at the maxHeight, got \(height)")
    }

    func testWrapperMountsAnNSScrollView() {
        // SwiftUI's `ScrollView` always bridges to `NSScrollView`.
        // The wrapper depends on this bridge for the cap-and-scroll
        // behaviour; if a future refactor moved off `ScrollView`
        // this assertion fires before the user ever sees a card
        // without scroll affordance.
        let (host, _) = renderAndInspect(
            content: { TallFixtureContent() }, cap: 240, width: 380)
        defer { host.window?.close() }

        XCTAssertNotNil(
            findScrollView(in: host),
            "wrapper should mount its content inside an NSScrollView")
    }

    // MARK: - Real DiffView content (the actual user scenario)

    func testSingleLineDiffShrinksToIntrinsic() {
        // The bug surface: bash permission card renders its command
        // through `DiffView` (an `NSViewRepresentable`). A one-line
        // command should not pad the card out to the 240pt cap — its
        // intrinsic height is well under 100pt.
        //
        // `DiffView.sizeThatFits(_:nsView:context:)` returns the
        // real height at a given width, so `.fixedSize(vertical:)`
        // can read through the representable bridge.
        let height = resolvedWrapperHeight(
            content: { SingleLineDiffFixture() },
            cap: 240,
            width: 380)

        XCTAssertGreaterThan(height, 0)
        XCTAssertLessThan(
            height, 100,
            "one-line diff should shrink the wrapper well below 240, got \(height)")
    }

    func testTallDiffCapsAtMaxHeight() {
        // 40-line diff easily exceeds 240pt. Same code path as the
        // single-line case but through the cap branch — verifies the
        // `NSViewRepresentable` ideal height feeds the `maxHeight`
        // clamp correctly.
        let height = resolvedWrapperHeight(
            content: { TallDiffFixture() },
            cap: 240,
            width: 380)

        XCTAssertEqual(
            height, 240, accuracy: 1.0,
            "tall diff should cap at the maxHeight, got \(height)")
    }

    // MARK: - Mounting + measurement

    /// Mount the wrapper offscreen, force one layout pass with a short
    /// drain (so any `NSViewRepresentable` child settles its
    /// `sizeThatFits`), then return the inner `NSScrollView`'s frame
    /// height.
    private func resolvedWrapperHeight<Content: View>(
        @ViewBuilder content: () -> Content,
        cap: CGFloat,
        width: CGFloat
    ) -> CGFloat {
        let (host, _) = renderAndInspect(
            content: content, cap: cap, width: width)
        defer { host.window?.close() }
        guard let scroll = findScrollView(in: host) else {
            XCTFail("expected an inner NSScrollView in the wrapper tree")
            return -1
        }
        return scroll.frame.height
    }

    /// Mount the wrapper through an `NSHostingView` in a borderless
    /// offscreen window (alpha 0.01, parked at -30k,-30k), force a
    /// layout pass, and return the host. The caller owns teardown;
    /// the returned host's `.window` is open.
    ///
    /// The container is intentionally much taller than the cap so the
    /// wrapper's intrinsic-vertical resolution is unconstrained from
    /// above — if the wrapper resolved to less than `cap`, we see the
    /// real shrunk height, not a clamp from the container.
    private func renderAndInspect<Content: View>(
        @ViewBuilder content: () -> Content,
        cap: CGFloat,
        width: CGFloat
    ) -> (NSHostingView<some View>, NSImage) {
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
        // Short drain for any `NSViewRepresentable` child (e.g.
        // `DiffView`) — the bridge's `makeNSView` / `updateNSView`
        // and the first `sizeThatFits` call all need a runloop tick
        // to land. With purely-SwiftUI content this is a no-op.
        drainRunLoop(seconds: 0.2, host: host)
        host.layoutSubtreeIfNeeded()

        return (host, NSImage(size: host.bounds.size))
    }

    private func drainRunLoop(seconds: TimeInterval, host: NSView) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(
                mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            host.layoutSubtreeIfNeeded()
        }
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews {
            if let hit = findScrollView(in: sub) { return hit }
        }
        return nil
    }
}

// MARK: - Fixtures

/// Hosts the wrapper at a fixed width. Vertical is left to the
/// wrapper's own `.fixedSize(vertical:)` — the host doesn't constrain
/// it, so the inner `NSScrollView` reports its real resolved height
/// without interference from the container.
private struct HostFixture<Content: View>: View {
    let maxHeight: CGFloat
    let width: CGFloat
    let content: Content

    var body: some View {
        BoundedHeightScrollView(maxHeight: maxHeight) {
            content
        }
        .frame(width: width)
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

/// `DiffView` rendering a single-line bash command. Mirrors what
/// `PermissionShellCardBody.commandDiffBlock` produces for the
/// canonical "rm -rf node_modules" bash card.
private struct SingleLineDiffFixture: View {
    var body: some View {
        DiffView(
            diff: DiffBlock(
                filePath: "command.sh",
                oldString: nil,
                newString: "rm -rf node_modules"))
    }
}

/// `DiffView` rendering a 40-line block — well over the 240pt cap.
/// Verifies the cap path through the representable bridge.
private struct TallDiffFixture: View {
    var body: some View {
        DiffView(
            diff: DiffBlock(
                filePath: "command.sh",
                oldString: nil,
                newString: (0..<40).map { "echo line \($0)" }.joined(separator: "\n")))
    }
}
