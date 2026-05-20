import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Captures the moment-by-moment state of a `.id(sid)`-driven transcript
/// swap. Unlike the existing settle-then-assert tests, this walks the
/// runloop in small ticks after triggering the swap and writes a PNG
/// per tick — so we can SEE what the user sees during the gap between
/// SwiftUI dismantling the outgoing `NativeTranscript2View` and the
/// new `NSTableView` settling at its anchor.
///
/// This mirrors what `RootView2` does in production: two controllers
/// each with a populated transcript, switched by flipping a binding
/// that drives `.id(sid)` on a child view. No SessionManager, no
/// bridge, no JSONL — just the swap mechanic. If the swap itself
/// produces a flicker frame, it shows up in `swap-frame-NN.png`.
@MainActor
final class HistorySwitchFlickerSnapshotTests: XCTestCase {

    @Observable @MainActor
    final class HarnessState {
        var sid: String
        init(_ initial: String) { sid = initial }
    }

    struct Harness: View {
        let state: HarnessState
        let controllerA: Transcript2Controller
        let controllerB: Transcript2Controller

        var body: some View {
            let ctrl = state.sid == "A" ? controllerA : controllerB
            // `.id(sid)` is the load-bearing piece — SwiftUI treats the
            // pre- and post-swap views as completely different identities,
            // tearing down the outgoing NSViewRepresentable and creating
            // a fresh one (new NSTableView, new coordinator.tableView
            // reassignment, new 0→positive frame transition).
            NativeTranscript2View(controller: ctrl)
                .id(state.sid)
                .environment(\.syntaxEngine, SyntaxHighlightEngine())
        }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testIdSwapFlickerSequence() throws {
        // Two distinct fixtures so the captured PNGs can be told apart.
        let controllerA = Transcript2Controller()
        controllerA.setHistory(Self.makeBlocks(prefix: "AAA", count: 60))

        let controllerB = Transcript2Controller()
        controllerB.setHistory(Self.makeBlocks(prefix: "BBB", count: 60))

        let state = HarnessState("A")
        let view = Harness(
            state: state, controllerA: controllerA, controllerB: controllerB)

        let size = CGSize(width: 600, height: 600)
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

        // Drain so A's initial mount settles to bottom.
        settle(hosting: hosting, duration: 0.6)
        XCTAssertTrue(controllerA.isAnchorSettled, "A should settle on initial mount")
        writePNG(hosting: hosting, name: "swap-00-A-settled")

        // FLIP. After this assignment SwiftUI starts the .id swap on its
        // next render pass. We do NOT drain a long settle here — we want
        // to see the in-flight frames.
        state.sid = "B"

        // Run the runloop in 20ms ticks and snapshot every tick. 20 ticks
        // × 20ms = 400ms covers the full settle window. Each PNG captures
        // what the screen would look like at that moment of the swap.
        let tickDuration: TimeInterval = 0.02
        for i in 1...20 {
            RunLoop.main.run(
                mode: .default,
                before: Date(timeIntervalSinceNow: tickDuration))
            hosting.view.layoutSubtreeIfNeeded()
            writePNG(
                hosting: hosting,
                name: String(format: "swap-%02d-tick", i),
                annotateAnchorSettled: controllerB.isAnchorSettled)
        }

        // Final settle to make sure B reached the bottom anchor.
        settle(hosting: hosting, duration: 0.4)
        XCTAssertTrue(controllerB.isAnchorSettled, "B should settle after swap")
        writePNG(hosting: hosting, name: "swap-99-B-settled")
    }

    // MARK: - Helpers

    private func settle(
        hosting: NSHostingController<AnyView>, duration: TimeInterval
    ) {
        hosting.view.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.main.run(
                mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        hosting.view.layoutSubtreeIfNeeded()
    }

    private func writePNG(
        hosting: NSHostingController<AnyView>,
        name: String,
        annotateAnchorSettled: Bool? = nil
    ) {
        let host = hosting.view
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        let suffix: String =
            switch annotateAnchorSettled {
            case .some(true): "-settled"
            case .some(false): "-pending"
            case .none: ""
            }
        let url = ViewSnapshot.writePNG(image, name: "\(name)\(suffix)")
        let attach = XCTAttachment(contentsOfFile: url)
        attach.name = "\(name)\(suffix).png"
        attach.lifetime = .keepAlways
        add(attach)
    }

    private static func makeBlocks(prefix: String, count: Int) -> [Block] {
        (0..<count).map { i in
            Block(
                id: UUID(),
                kind: .paragraph(inlines: [
                    .text("\(prefix) line \(i) — quick brown fox over the lazy dog")
                ]))
        }
    }
}
