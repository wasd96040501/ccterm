import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// End-to-end coverage for `Transcript2SearchCoordinator` driven through
/// the public `Transcript2Controller.runSearch` surface — the layer that
/// had no regression gate (only `ToolGroupSearchableRegionsTests` pinned
/// the layout-level `searchableRegions`, not the scan → hits → nav chain).
///
/// The transcript is mounted offscreen at its real width so the scan runs
/// against a settled `layoutWidth` (a 0-width `TextLayout` collapses to
/// `.empty`, which would hide a real regression behind an empty haystack).
@MainActor
final class TranscriptSearchCoordinatorTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func para(_ text: String) -> Block {
        Block(id: UUID(), kind: .paragraph(inlines: [.text(text)]))
    }

    /// The most basic contract: a literal query against plain paragraph
    /// text must produce hits and seat the nav cursor.
    func testParagraphSearchYieldsHits() {
        let controller = Transcript2Controller()
        controller.apply(
            .append([
                para("the quick brown fox"),
                para("an apple a day"),
                para("apple pie and apple cider"),
            ]))
        let mounted = MountedTranscript.mount(controller: controller)
        defer { mounted.teardown() }

        let search = controller.coordinator.search
        controller.runSearch("apple")

        XCTAssertEqual(
            search.totalHits, 3,
            "literal 'apple' appears 3× across the paragraphs")
        XCTAssertEqual(
            search.currentIndex, 0,
            "first hit must be the seated nav cursor after a fresh query")
    }

    /// An expanded tool-group child's body text must be reachable by
    /// search. This is the case the user reported broken ("even an
    /// expanded block won't highlight or nav").
    func testExpandedToolGroupChildSearchYieldsHits() {
        let groupId = UUID()
        let bashId = UUID()
        let group = ToolGroupBlock(
            activeTitle: "Running command",
            expandedActiveTitle: "Running 1 command",
            completedTitle: "Ran 1 command",
            children: [
                .bash(
                    BashChild(
                        id: bashId,
                        label: "Ran 'ls'",
                        activeLabel: "Running 'ls'",
                        command: "ls",
                        stdout: "apple banana\ncherry apple",
                        stderr: nil))
            ])
        let controller = Transcript2Controller()
        controller.apply(.append([Block(id: groupId, kind: .toolGroup(group))]))
        let mounted = MountedTranscript.mount(controller: controller)
        defer { mounted.teardown() }

        // Expand the group host and the child so the body is laid out and
        // its text enters the scan.
        controller.coordinator.toggleFold(id: groupId)
        controller.coordinator.toggleFold(id: bashId)

        let search = controller.coordinator.search
        controller.runSearch("apple")

        XCTAssertEqual(
            search.totalHits, 2,
            "literal 'apple' appears 2× in the expanded bash stdout")
        XCTAssertEqual(search.currentIndex, 0)
    }

    /// The render-side data path: after a query, the matched block's
    /// visible cell must actually carry the highlight specs (this is what
    /// `BlockCellView.draw` paints the yellow rects from). Covers the
    /// "hits computed but nothing painted" failure mode.
    func testSearchPushesHighlightsToVisibleCell() {
        let targetId = UUID()
        let controller = Transcript2Controller()
        controller.apply(
            .append([
                para("the quick brown fox"),
                Block(id: targetId, kind: .paragraph(inlines: [.text("an apple a day")])),
            ]))
        let mounted = MountedTranscript.mount(controller: controller)
        defer { mounted.teardown() }

        controller.runSearch("apple")

        guard let row = controller.coordinator.blockIds.firstIndex(of: targetId) else {
            return XCTFail("target block not found in transcript")
        }
        let cell =
            mounted.table.view(atColumn: 0, row: row, makeIfNecessary: true) as? BlockCellView
        XCTAssertNotNil(cell, "matched row must vend a BlockCellView")
        XCTAssertEqual(
            cell?.searchHighlights?.count, 1,
            "the visible cell over a hit must carry exactly one highlight spec to paint")
    }

    /// The toolbar input edge: a text change on the window's
    /// `NSSearchField` must route through `TranscriptSearchToolbarBridge`
    /// into the current controller's `runSearch`. Covers the only segment
    /// the other tests don't — the AppKit search-field delegate wiring
    /// introduced when the main window moved to AppKit.
    func testToolbarBridgeRoutesKeystrokesToController() {
        let controller = Transcript2Controller()
        controller.apply(.append([para("an apple a day")]))
        let mounted = MountedTranscript.mount(controller: controller)
        defer { mounted.teardown() }

        let field = NSSearchField()
        let bridge = TranscriptSearchToolbarBridge(
            searchField: field,
            searchBus: TranscriptSearchBus(),
            controllerProvider: { controller })
        field.delegate = bridge

        field.stringValue = "apple"
        bridge.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: field))

        XCTAssertEqual(
            controller.coordinator.search.totalHits, 1,
            "a search-field text change must reach the controller's runSearch")
    }

    /// Diff-bearing tool children (fileEdit / read) expose their body via
    /// a `.diff` region, not a `.textCard` one — the path the bash test
    /// above doesn't cover and that history sessions hit constantly. This
    /// is the case the user flagged ("toolblock won't search").
    func testExpandedFileEditDiffSearchYieldsHits() {
        let groupId = UUID()
        let editId = UUID()
        let group = ToolGroupBlock(
            activeTitle: "Editing file",
            expandedActiveTitle: "Editing 1 file",
            completedTitle: "Edited 1 file",
            children: [
                .fileEdit(
                    FileEditChild(
                        id: editId,
                        label: "Edit foo.swift",
                        activeLabel: "Editing foo.swift",
                        filePath: "foo.swift",
                        diff: DiffBlock(
                            filePath: "foo.swift",
                            oldString: "let apple = 1",
                            newString: "let apple = 2")))
            ])
        let controller = Transcript2Controller()
        controller.apply(.append([Block(id: groupId, kind: .toolGroup(group))]))
        let mounted = MountedTranscript.mount(controller: controller)
        defer { mounted.teardown() }

        controller.coordinator.toggleFold(id: groupId)
        controller.coordinator.toggleFold(id: editId)

        controller.runSearch("apple")

        XCTAssertGreaterThan(
            controller.coordinator.search.totalHits, 0,
            "expanded fileEdit diff body must be searchable")
    }

    /// The auto-expand-on-nav contract: with hits already landed in an
    /// expanded child, collapsing that child and then navigating must
    /// re-open it (so the highlight becomes visible again). Observed via
    /// whether the child's body text is back in the searchable regions —
    /// a folded child contributes none.
    func testNavReExpandsCollapsedChildWithHit() {
        let groupId = UUID()
        let bashId = UUID()
        let group = ToolGroupBlock(
            activeTitle: "Running command",
            expandedActiveTitle: "Running 1 command",
            completedTitle: "Ran 1 command",
            children: [
                .bash(
                    BashChild(
                        id: bashId,
                        label: "Ran 'ls'",
                        activeLabel: "Running 'ls'",
                        command: "ls",
                        stdout: "apple banana\ncherry apple",
                        stderr: nil))
            ])
        let controller = Transcript2Controller()
        controller.apply(.append([Block(id: groupId, kind: .toolGroup(group))]))
        let mounted = MountedTranscript.mount(controller: controller)
        defer { mounted.teardown() }

        func bodyIsSearchable() -> Bool {
            (controller.coordinator.selectionAdapter(forBlockId: groupId)?
                .searchableRegions() ?? [])
                .contains { $0.text.contains("apple") }
        }

        // Expand, search (hits land), then collapse the child.
        controller.coordinator.toggleFold(id: groupId)
        controller.coordinator.toggleFold(id: bashId)
        controller.runSearch("apple")
        XCTAssertEqual(controller.coordinator.search.totalHits, 2)
        XCTAssertTrue(bodyIsSearchable(), "expanded child body should be searchable")

        controller.coordinator.toggleFold(id: bashId)
        XCTAssertFalse(bodyIsSearchable(), "folded child contributes no searchable body")

        // Navigating to the (still-recorded) hit must re-open the child.
        controller.nextSearchHit()
        XCTAssertTrue(
            bodyIsSearchable(),
            "nav must auto-expand the collapsed child so its highlight resurfaces")
    }

    /// THE user-reported case, reproduced through the real history path:
    /// a Read tool loaded by the reverse-streaming backfill pipeline,
    /// expanded, then searched. If this fails while the hand-built
    /// fileEdit/bash cases pass, the bug is in what the history builder
    /// produces (or how its body becomes searchable), not in the scanner.
    func testHistoryReadToolBodyIsSearchableAfterExpand() async {
        let tu = "tu-read"
        let controller = Transcript2Controller()
        let loaded = expectation(description: "loaded")
        let pipeline = TranscriptBackfillPipeline(
            source: FakeReversePageSource([
                [
                    Message2Fixtures.assistantRead(
                        toolUseId: tu, filePath: "/tmp/x.txt"),
                    Message2Fixtures.userToolResult(
                        toolUseId: tu, text: "let apple = 1\nlet banana = 2"),
                ]
            ]),
            controller: controller,
            budget: 40,
            onLoaded: { loaded.fulfill() })
        pipeline.start(width: 0)
        await fulfillment(of: [loaded], timeout: 5)

        let mounted = MountedTranscript.mount(controller: controller)
        defer { mounted.teardown() }

        let coord = controller.coordinator
        guard
            let groupId = coord.blockIds.first(where: {
                if case .toolGroup = coord.block(forId: $0)?.kind { return true }
                return false
            }),
            case .toolGroup(let group) = coord.block(forId: groupId)?.kind
        else {
            return XCTFail("history load produced no toolGroup")
        }

        // Expand the group host and the Read child so its body lays out.
        coord.toggleFold(id: groupId)
        if let childId = group.children.first?.id {
            coord.toggleFold(id: childId)
        }

        controller.runSearch("apple")
        XCTAssertGreaterThan(
            coord.search.totalHits, 0,
            "expanded Read tool body loaded from history must be searchable")
    }

    /// Hypothesis check for the user-reported "expanded tool won't search":
    /// the tool's HEADER label (file path / command / tool name) is not in
    /// `searchableRegions` — only the expanded body is. A token that lives
    /// only in the file path yields zero hits even with the child expanded,
    /// while a token in the body is found. If this passes, "I searched a
    /// filename and the tool didn't match" is explained by design, not a
    /// scanner bug.
    func testToolHeaderLabelIsNotSearchable() async {
        let tu = "tu-zebra"
        let controller = Transcript2Controller()
        let loaded = expectation(description: "loaded")
        let pipeline = TranscriptBackfillPipeline(
            source: FakeReversePageSource([
                [
                    Message2Fixtures.assistantRead(
                        toolUseId: tu, filePath: "/tmp/zebrafile.txt"),
                    Message2Fixtures.userToolResult(
                        toolUseId: tu, text: "let apple = 1"),
                ]
            ]),
            controller: controller,
            budget: 40,
            onLoaded: { loaded.fulfill() })
        pipeline.start(width: 0)
        await fulfillment(of: [loaded], timeout: 5)

        let mounted = MountedTranscript.mount(controller: controller)
        defer { mounted.teardown() }

        let coord = controller.coordinator
        guard
            let groupId = coord.blockIds.first(where: {
                if case .toolGroup = coord.block(forId: $0)?.kind { return true }
                return false
            }),
            case .toolGroup(let group) = coord.block(forId: groupId)?.kind
        else {
            return XCTFail("history load produced no toolGroup")
        }
        coord.toggleFold(id: groupId)
        if let childId = group.children.first?.id {
            coord.toggleFold(id: childId)
        }

        // "zebra" lives ONLY in the file path → header label, never the body.
        controller.runSearch("zebra")
        let headerHits = coord.search.totalHits
        // "apple" lives in the body (tool_result content).
        controller.runSearch("apple")
        let bodyHits = coord.search.totalHits

        XCTAssertEqual(
            headerHits, 0,
            "the file path shows in the header label, which search does not cover")
        XCTAssertGreaterThan(
            bodyHits, 0, "the body content is searchable for contrast")
    }
}
