import AgentSDK
import AppKit
import TranscriptKit
import XCTest

@testable import ccterm

/// The sample session in a transcript tab — every card kind, the long group
/// opened — and the documents its cards open, in both appearances, as the
/// window server composited them. Review-only:
/// `make test-unit FILTER=TranscriptCardsSnapshotTests`, then look at
/// `/tmp/ccterm-screenshots/TranscriptCards-*.png`.
@MainActor
final class TranscriptCardsSnapshotTests: XCTestCase {
    private var root: URL!
    private var transcriptURL: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        transcriptURL = try SampleSession.write(into: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTranscript() async throws {
        for (look, appearance) in [("Light", NSAppearance.Name.aqua), ("Dark", .darkAqua)] {
            let controller = TranscriptViewController(fileURL: transcriptURL, title: "Sample")
            let window = WindowCapture.window(for: controller, size: NSSize(width: 760, height: 1100), appearance: appearance)
            defer { window.close() }
            // A window of a process that never activates doesn't report it.
            controller.viewDidAppear()
            let transcript = try XCTUnwrap(findAll(TranscriptView.self, in: controller.view).first)
            await wait { transcript.numberOfRows > 30 }

            transcript.scrollToRow(at: 0, scrollPosition: .top)
            await settle(window)
            // The longest group — the one that scrolls inside its card — opened.
            let groups = findAll(ToolGroupView.self, in: controller.view)
            let longest = groups.max { lhs, rhs in
                steps(in: lhs, of: transcript) < steps(in: rhs, of: transcript)
            }
            if let longest { controller.cardDidToggle(longest) }
            for (index, row) in [0, 9, 26].enumerated() {
                transcript.scrollToRow(at: row, scrollPosition: .top)
                await settle(window)
                try await WindowCapture.capture(window, named: "TranscriptCards-\(look)-\(index)")
            }
        }
    }

    func testDocuments() async throws {
        let outline = TranscriptOutline(try Transcript(contentsOf: transcriptURL), source: transcriptURL)
        let steps = outline.rows.flatMap { row -> [ToolStep] in
            guard case .tools(let group)? = outline.cards[row.id] else { return [] }
            return group.steps
        }
        // Positions in the sample session's calls, in order.
        let wanted: [(String, Int)] = [
            ("File", 0), ("FileRange", 1), ("Grep", 3), ("Comparison", 5), ("MultiEdit", 6), ("NewFile", 7),
            ("Rewrite", 8), ("Command", 11), ("FailedCommand", 12), ("TaskOutput", 14), ("BashOutput", 16),
            ("WebFetch", 18), ("Report", 20), ("Todos", 22), ("Plan", 26), ("MCP", 28),
        ]
        for (name, index) in wanted {
            guard steps.indices.contains(index), let document = steps[index].document else {
                XCTFail("no document for \(name)")
                continue
            }
            for (look, appearance) in [("Light", NSAppearance.Name.aqua), ("Dark", .darkAqua)] {
                let controller = ToolDocumentViewController(document: document)
                let window = WindowCapture.window(
                    for: controller, size: NSSize(width: 820, height: 460), appearance: appearance)
                controller.viewDidAppear()
                await settle(window)
                try await WindowCapture.capture(window, named: "TranscriptCards-Doc-\(name)-\(look)")
                window.close()
            }
        }
    }

    // MARK: - Scaffolding

    private func steps(in view: ToolGroupView, of transcript: TranscriptView) -> Int {
        view.frame.height > 0 ? findAll(ToolStepRowView.self, in: view).filter { !$0.isHidden }.count : 0
    }

    private func wait(until condition: @escaping @MainActor () -> Bool) async {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in MainActor.assumeIsolated { condition() } }, object: nil)
        await fulfillment(of: [expectation], timeout: 10)
    }

    /// A few turns for layout, the load's next hop, and a display.
    private func settle(_ window: NSWindow) async {
        for _ in 0..<10 { await Task.yield() }
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private func findAll<V: NSView>(_ type: V.Type, in view: NSView) -> [V] {
        var found: [V] = []
        if let match = view as? V { found.append(match) }
        for subview in view.subviews { found += findAll(type, in: subview) }
        return found
    }
}
