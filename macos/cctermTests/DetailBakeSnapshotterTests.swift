import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Exercises the `DetailBakeSnapshotter` + `DetailBakeProbe` pair against
/// a real SwiftUI host: mount a coloured rectangle under the probe in a
/// hidden offscreen window, settle, then `snapshot()` and assert the
/// resulting `NSImage` reflects the content.
///
/// Why this matters: the snapshotter is the load-bearing piece of the
/// sidebar bake (`RootView2`'s overlay reads its output). If the probe's
/// ancestor-walk picks the wrong container — either the 0-pt probe
/// itself, or a parent wider than the detail content — the bake either
/// shows an empty bitmap or stretches sidebar pixels across the detail
/// pane.
@MainActor
final class DetailBakeSnapshotterTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSnapshotCapturesProbedDetailContent() throws {
        let snapshotter = DetailBakeSnapshotter()
        // Detail-pane fixture: a sentinel coloured strip + label, mounted
        // through the same `.background(DetailBakeProbe)` pattern
        // `RootView2` uses. The colours are deliberately strong so the
        // `isUniform` probe in the assert below can never false-negative
        // on a successful snapshot.
        let view = ZStack {
            LinearGradient(
                colors: [.orange, .purple],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
            Text("DETAIL FIXTURE")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 480, height: 360)
        .background(DetailBakeProbe(snapshotter: snapshotter))

        let size = CGSize(width: 480, height: 360)
        let hosting = NSHostingController(rootView: AnyView(view))
        hosting.view.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(
                origin: CGPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        window.contentViewController = hosting
        window.ccterm_orderFrontForTesting()
        defer {
            window.contentViewController = nil
            window.close()
        }

        // Drain runloop so the probe's deferred `DispatchQueue.main.async`
        // assignment lands and AppKit finishes its layout pass.
        hosting.view.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            RunLoop.main.run(
                mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        hosting.view.layoutSubtreeIfNeeded()

        guard let image = snapshotter.snapshot() else {
            return XCTFail("snapshotter returned nil — probe never registered")
        }
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)

        // Captured bitmap must look like the detail content (gradient +
        // text) — i.e. *not* a single flat colour. The probe walking to
        // the wrong ancestor is the failure mode this guards against.
        let bitmap =
            image.representations.compactMap {
                $0 as? NSBitmapImageRep
            }.first
        guard let bitmap else {
            return XCTFail("snapshot has no bitmap representation")
        }
        XCTAssertFalse(
            isUniform(bitmap),
            "snapshot is a flat colour — probe walked to an empty ancestor"
        )

        // Width of the captured bitmap should match the fixture width
        // (within rounding). If the walk drifted to a wider parent
        // (e.g. the whole window), this asserts the regression.
        XCTAssertEqual(
            Int(image.size.width), 480,
            "captured width should match detail-fixture frame")
    }

    /// Same cheap-uniform probe used by `TranscriptDemoSnapshotTests`.
    private func isUniform(_ rep: NSBitmapImageRep) -> Bool {
        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        guard w > 4, h > 4 else { return true }
        let probes: [(Int, Int)] = [
            (w / 4, h / 4), (w / 2, h / 4), (3 * w / 4, h / 4),
            (w / 4, h / 2), (w / 2, h / 2), (3 * w / 4, h / 2),
            (w / 4, 3 * h / 4), (w / 2, 3 * h / 4), (3 * w / 4, 3 * h / 4),
        ]
        let colors = probes.compactMap { rep.colorAt(x: $0.0, y: $0.1) }
        guard let first = colors.first else { return true }
        return colors.allSatisfy { $0 == first }
    }
}
