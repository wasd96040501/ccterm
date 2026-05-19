import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Long-running capture across the full Phase A → Phase B timeline of
/// `SessionRuntime.loadHistory(overrideURL:)`. Earlier flicker tests
/// drove `Transcript2Controller.setHistory(...)` directly — Phase A
/// semantics only. This test runs the real two-phase orchestrator on
/// a JSONL fixture sized so Phase B has work to do, captures a PNG
/// per tick across the full window, and annotates each filename with
/// the runtime's `historyLoadState` plus `isAnchorSettled`.
///
/// Goal: see whether Phase B's `.prepended` (rows inserted at the
/// top of the table) produces a visible visual jump even when
/// `isAnchorSettled` is correctly held at `true` — i.e. flicker the
/// bake mechanism could never cover.
@MainActor
final class HistoryPhaseBFlickerSnapshotTests: XCTestCase {

    private var tempFile: TempJSONLFile?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        tempFile?.remove()
        tempFile = nil
    }

    func testPhaseATotailedFollowedByPhaseBPrependFrameSequence() async throws {
        // 120 entries; tailTarget=40 so Phase B has ~80 prefix entries
        // to prepend off-main. Big enough that Phase B's main-thread
        // prepend isn't trivially fast.
        let lines = Message2Fixtures.bulkAssortedJSONL(count: 120)
        let file = try TempJSONLFile(lines)
        tempFile = file

        let runtime = SessionRuntime(
            sessionId: UUID().uuidString,
            repository: InMemorySessionRepository())
        let session = Session(runtime: runtime)

        let size = CGSize(width: 600, height: 600)
        let view = NativeTranscript2View(controller: session.controller)
            .environment(\.syntaxEngine, SyntaxHighlightEngine())
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

        // Kick the load. Phase A's MainActor hops need the cooperative
        // scheduler to advance, which `Task.sleep` provides; bare
        // `RunLoop.main.run` doesn't pump main-actor jobs reliably.
        runtime.loadHistory(overrideURL: file.url, tailTarget: 40)

        // Capture for 2 seconds, one frame every 20ms = 100 PNGs.
        // That's long enough that Phase A (.tailLoaded → .reset) and
        // Phase B (.prepended) both land within the window even on a
        // slow runner.
        let tickInterval: TimeInterval = 0.02
        let totalTicks = 100
        var firstTickAfterTailLoad: Int? = nil
        var firstTickAfterPrefixLoad: Int? = nil
        for i in 1...totalTicks {
            try? await Task.sleep(nanoseconds: UInt64(tickInterval * 1_000_000_000))
            hosting.view.layoutSubtreeIfNeeded()

            let state = runtime.historyLoadState
            let settled = session.controller.isAnchorSettled
            let blocks = session.controller.blockCount

            if case .tailLoaded = state, firstTickAfterTailLoad == nil {
                firstTickAfterTailLoad = i
            }
            if state == .loaded, firstTickAfterPrefixLoad == nil {
                firstTickAfterPrefixLoad = i
            }

            // Throttle PNG output to keep the xcresult bundle manageable:
            // every tick for the first 30 (covers cold-load + Phase A
            // settle), then every 5th to surface Phase B's window.
            let shouldWritePNG = i <= 30 || i.isMultiple(of: 5)
            if shouldWritePNG {
                let stateTag: String = {
                    switch state {
                    case .notLoaded: return "notLoaded"
                    case .loadingTail: return "loadingTail"
                    case .tailLoaded: return "tailLoaded"
                    case .loaded: return "loaded"
                    case .failed: return "failed"
                    }
                }()
                writePNG(
                    hosting: hosting,
                    name: String(
                        format:
                            "phaseB-%03d-%@-blocks=%d-settled=%@",
                        i, stateTag, blocks, settled ? "Y" : "N"))
            }
        }

        print("[phaseB-test] tailLoaded reached at tick=\(firstTickAfterTailLoad ?? -1)")
        print("[phaseB-test] loaded     reached at tick=\(firstTickAfterPrefixLoad ?? -1)")

        XCTAssertEqual(
            runtime.historyLoadState, .loaded,
            "expected .loaded by end of 2-second window")
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
}
