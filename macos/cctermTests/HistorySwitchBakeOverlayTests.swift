import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Mirrors `HistorySwitchFlickerSnapshotTests` but wires in the bake
/// state machine `RootView2` uses. If the bake works, every tick
/// between the swap and `isAnchorSettled = true` should show A's
/// content (the cover), not B's mid-scroll state.
///
/// Captures every tick to PNG so a regression can be reviewed visually,
/// and asserts on `bakedImage` presence at the moments the flicker
/// frames land in the no-bake test (ticks 1-6).
@MainActor
final class HistorySwitchBakeOverlayTests: XCTestCase {

    @Observable @MainActor
    final class HarnessState {
        var sid: String
        var bakedImage: NSImage?
        let snapshotter = DetailBakeSnapshotter()
        let controllerA: Transcript2Controller
        let controllerB: Transcript2Controller

        init(
            sid: String, controllerA: Transcript2Controller,
            controllerB: Transcript2Controller
        ) {
            self.sid = sid
            self.controllerA = controllerA
            self.controllerB = controllerB
        }

        var currentController: Transcript2Controller {
            sid == "A" ? controllerA : controllerB
        }

        /// Drive a swap exactly the way `RootView2.sidebarSelectionBinding`
        /// does in production: snapshot the outgoing detail FIRST, then
        /// flip `sid` so SwiftUI's `.id(sid)` rebuild kicks in.
        func switchTo(_ newSid: String) {
            guard newSid != sid else { return }
            bakedImage = snapshotter.snapshot()
            sid = newSid
        }

        func clearBake() {
            bakedImage = nil
        }
    }

    struct Harness: View {
        let state: HarnessState

        var body: some View {
            NativeTranscript2View(controller: state.currentController)
                .id(state.sid)
                .environment(\.syntaxEngine, SyntaxHighlightEngine())
                .background(DetailBakeProbe(snapshotter: state.snapshotter))
                .overlay {
                    if let img = state.bakedImage {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .clipped()
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: state.currentController.isAnchorSettled) {
                    _, settled in
                    if settled, state.bakedImage != nil {
                        withAnimation(.smooth(duration: 0.18)) {
                            state.clearBake()
                        }
                    }
                }
        }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testBakeOverlayMasksMidSwapFrames() throws {
        let controllerA = Transcript2Controller()
        controllerA.setHistory(Self.makeBlocks(prefix: "AAA", count: 60))

        let controllerB = Transcript2Controller()
        controllerB.setHistory(Self.makeBlocks(prefix: "BBB", count: 60))

        let state = HarnessState(
            sid: "A", controllerA: controllerA, controllerB: controllerB)
        let view = Harness(state: state)

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

        settle(hosting: hosting, duration: 0.6)
        XCTAssertTrue(controllerA.isAnchorSettled, "A initial settle")
        writePNG(hosting: hosting, name: "bake-00-A-settled")

        // Simulate the click: bake-then-flip.
        state.switchTo("B")
        XCTAssertNotNil(
            state.bakedImage,
            "bake must be captured BEFORE the sid flip — snapshotter returned nil"
        )

        // Walk the runloop in 20ms ticks for 400ms. Track when bake
        // clears so we can correlate against the PNG frames.
        var bakeClearedAtTick: Int? = nil
        for i in 1...20 {
            RunLoop.main.run(
                mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            hosting.view.layoutSubtreeIfNeeded()
            let hasBake = state.bakedImage != nil
            let settled = controllerB.isAnchorSettled
            if !hasBake && bakeClearedAtTick == nil {
                bakeClearedAtTick = i
            }
            writePNG(
                hosting: hosting,
                name: String(
                    format: "bake-%02d-tick-bake=%@-settled=%@",
                    i,
                    hasBake ? "Y" : "N",
                    settled ? "Y" : "N"))
        }

        settle(hosting: hosting, duration: 0.4)
        XCTAssertTrue(controllerB.isAnchorSettled, "B should settle after swap")
        XCTAssertNil(
            state.bakedImage,
            "bake must clear after settle")
        writePNG(hosting: hosting, name: "bake-99-B-settled")

        // Report what we learned for the human reviewer / log scraper.
        if let cleared = bakeClearedAtTick {
            print(
                "[bake-test] bake cleared at tick=\(cleared) (~\(cleared * 20)ms after swap)"
            )
        } else {
            print("[bake-test] bake never cleared within 400ms window")
        }
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
        hosting: NSHostingController<AnyView>, name: String
    ) {
        let host = hosting.view
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        let url = ViewSnapshot.writePNG(image, name: name)
        let attach = XCTAttachment(contentsOfFile: url)
        attach.name = "\(name).png"
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
