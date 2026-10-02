import AgentSDK
import AppKit
import TranscriptKit
import TranscriptWorkspace
import XCTest

@testable import ccterm

/// A transcript tab loading a file: every message arrives, the reader starts
/// at the end, a file that can't be read still shows something, and closing
/// the tab stops the load.
@MainActor
final class TranscriptViewControllerTests: XCTestCase {
    typealias Rows = SessionDirectoryFixture

    private var fixture: SessionDirectoryFixture!
    private var stage: AppKitStage?

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try SessionDirectoryFixture()
    }

    override func tearDown() async throws {
        stage?.teardown()
        fixture.remove()
    }

    /// A linear conversation of `turns` prompt/answer pairs: `2 × turns` rows.
    private func writeConversation(_ relative: String, turns: Int) throws -> URL {
        var lines: [String] = []
        var parent: String?
        for turn in 0..<turns {
            lines.append(Rows.user("u\(turn)", parent: parent, "Question \(turn)"))
            lines.append(Rows.assistant("a\(turn)", parent: "u\(turn)", "Answer **\(turn)**"))
            parent = "a\(turn)"
        }
        try fixture.write(relative, lines)
        return fixture.url(relative)
    }

    private func mountTab(_ url: URL) throws -> TranscriptView {
        let stage = AppKitStage.mount(
            TranscriptViewController(fileURL: url, title: "t", sessions: .reading(), acceptsInput: false))
        self.stage = stage
        stage.rootViewController.viewDidAppear()
        return try XCTUnwrap(stage.find(TranscriptView.self))
    }

    func testLoadsEveryMessageAndStartsAtTheEnd() throws {
        let transcript = try mountTab(try writeConversation("-p/s.jsonl", turns: 200))
        XCTAssertTrue(stage!.drainUntil(timeout: 10) { transcript.numberOfRows == 400 })
        stage!.drain(seconds: 0.2)

        // With the scroll applied, so a row in view lies inside the bounds.
        let last = transcript.rect(ofRow: 399)
        let visible = transcript.bounds
        XCTAssertTrue(
            visible.insetBy(dx: 0, dy: -1).contains(last), "last row \(last) not in view \(visible)")
    }

    func testAnUnreadableFileShowsANote() throws {
        let transcript = try mountTab(fixture.url("-p/missing.jsonl"))
        XCTAssertTrue(stage!.drainUntil(timeout: 5) { transcript.numberOfRows == 1 })
    }

    func testClosingTheTabStopsTheLoad() throws {
        let url = try writeConversation("-p/long.jsonl", turns: 3_000)
        let stage = AppKitStage.mainSplit()
        self.stage = stage
        let split = try XCTUnwrap(stage.mainSplit)
        let sidebar = try XCTUnwrap(split.splitViewItems[0].viewController as? SidebarViewController)
        let area = try XCTUnwrap(split.splitViewItems[1].viewController as? EditorAreaViewController)
        split.sidebarViewController(
            sidebar, didOpen: LibraryNode(id: url.path, kind: .session, title: "long", transcriptURL: url, children: [])
        )
        let transcript = try XCTUnwrap(stage.find(TranscriptView.self))
        XCTAssertTrue(stage.drainUntil(timeout: 10) { transcript.numberOfRows > 0 })

        let loaded = transcript.numberOfRows
        XCTAssertLessThan(loaded, 6_000)
        area.closeTab(nil)
        stage.drain(seconds: 0.5)
        XCTAssertEqual(transcript.numberOfRows, loaded)
    }
}
