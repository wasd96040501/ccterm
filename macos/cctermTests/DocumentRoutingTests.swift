import AgentSDK
import AppKit
import TranscriptWorkspace
import XCTest

@testable import ccterm

/// Where a document a transcript opens goes (design/transcript/README.md
/// "Opening a document beside the transcript"): the other editor, splitting
/// the area on the first; a click shows it in that editor's temporary tab and
/// the next click replaces it there; a double-click gives it a tab that
/// stays; an open document is brought forward; history makes a closed one
/// again from its reference.
@MainActor
final class DocumentRoutingTests: XCTestCase {
    private var stage: AppKitStage!
    private var split: MainSplitViewController!
    private var area: EditorAreaViewController!
    private var transcript: TranscriptViewController!
    private let url = URL(fileURLWithPath: "/nonexistent/a.jsonl")

    override func setUp() async throws {
        continueAfterFailure = false
        stage = AppKitStage.mainSplit()
        await stage.settle()
        split = try XCTUnwrap(stage.mainSplit)
        area = try XCTUnwrap(split.splitViewItems[1].viewController as? EditorAreaViewController)
        let sidebar = try XCTUnwrap(split.splitViewItems[0].viewController as? SidebarViewController)
        let session = LibraryNode(id: url.path, kind: .session, title: "a", transcriptURL: url, children: [])
        split.sidebarViewController(sidebar, didOpen: session)
        transcript = try XCTUnwrap(area.activeViewController?.children.lazy.compactMap { $0 as? TranscriptViewController }.first)
    }

    override func tearDown() async throws {
        stage.teardown()
    }

    func testAClickOpensTheDocumentInTheOtherEditorsTemporaryTab() throws {
        open(document("c1"), pinned: false)
        XCTAssertEqual(area.groups.count, 2, "the first document splits the area")
        XCTAssertEqual(references(in: area.groups[0]), [], "the transcript's editor keeps only the transcript")
        let other = area.groups[1]
        XCTAssertEqual(references(in: other), [reference("c1")])
        XCTAssertIdentical(other.previewTabViewItem, other.tabViewItems.first)
        XCTAssertTrue(other.tabViewItems.first?.viewController is DocumentViewController)
    }

    func testTheNextClickReplacesItWhereItStands() {
        open(document("c1"), pinned: false)
        open(document("c2"), pinned: false)
        XCTAssertEqual(area.groups.count, 2)
        XCTAssertEqual(references(in: area.groups[1]), [reference("c2")])
    }

    func testADoubleClickGivesItATabThatStays() {
        open(document("c1"), pinned: true)
        open(document("c2"), pinned: false)
        let other = area.groups[1]
        XCTAssertEqual(references(in: other), [reference("c1"), reference("c2")])
        XCTAssertIdentical(other.previewTabViewItem, other.tabViewItems.last)
    }

    func testAnOpenDocumentIsBroughtForwardNotOpenedAgain() {
        open(document("c1"), pinned: true)
        open(document("c2"), pinned: true)
        open(document("c1"), pinned: false)
        let other = area.groups[1]
        XCTAssertEqual(references(in: other), [reference("c1"), reference("c2")])
        XCTAssertEqual(
            other.tabViewItems[other.selectedTabViewItemIndex].identifier as? TranscriptTab,
            .document(reference("c1")))
    }

    func testHistoryMakesAClosedDocumentAgainFromItsReference() throws {
        let item = try XCTUnwrap(
            split.editorArea(area, tabViewItemWithIdentifier: TranscriptTab.document(reference("c1"))))
        XCTAssertEqual(item.identifier as? TranscriptTab, .document(reference("c1")))
        XCTAssertTrue(item.viewController is DocumentViewController)
    }

    /// What a transcript's press on an item asks of the window.
    private func open(_ document: Document, pinned: Bool) {
        split.transcriptTab(
            transcript, didRequestOpen: .document(document.reference), pinned: pinned,
            makeItem: {
                TranscriptTab.makeDocumentItem(
                    document, sessions: .reading { _ in Transcript(data: Data()) }, delegate: split)
            })
    }

    private func reference(_ id: String) -> DocumentReference {
        DocumentReference(transcriptURL: url, id: id)
    }

    private func document(_ id: String) -> Document {
        Document(reference: reference(id), content: .compactionSummary("Summary \(id)"), workingDirectory: nil)
    }

    private func references(in group: EditorGroupViewController) -> [DocumentReference] {
        group.tabViewItems.compactMap {
            if case .document(let reference)? = TranscriptTab(identifier: $0.identifier) { reference } else { nil }
        }
    }
}
