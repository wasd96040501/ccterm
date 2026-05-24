import XCTest

@testable import ccterm

/// Pins the two pure routing decisions that translate
/// `MainSelection` → detail-pane content:
///
/// 1. `TranscriptDetailComposeStack.content(for:draftSessionId:)` —
///    what the always-mounted input-bar overlay should render. The
///    invariant under test: `.archive` / `.demo` / `.none` collapse to
///    `.none`, so no input chrome floats on top of side-branch pages.
///    Pre-fix, this branch fell through to `ChatRestingBar(sessionId:
///    "__archive__")`, which mounted a SwiftUI input bar that swallowed
///    clicks on the Archive page's Unarchive button.
/// 2. `TranscriptDetailViewController.sideBranchKind(for:)` — which
///    side-branch VC (if any) the detail VC should mount under the
///    overlays. The invariant: only `.archive` / `.demo` produce a
///    side branch; chat-flavored cases route to the transcript.
@MainActor
final class TranscriptDetailRoutingTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - ComposeStack content routing

    func testComposeContent_archiveSelectionRendersNoInputChrome() {
        // The bug fix: when the user opens the Archive tab, the
        // input-bar host must collapse to nothing — otherwise the
        // bottom-anchored ChatRestingBar (and its embedded
        // InputBarChrome) eats clicks on the Archive list, making
        // the per-row Unarchive button unpressable.
        let content = TranscriptDetailComposeStack.content(
            for: .archive, draftSessionId: "draft-1")
        XCTAssertEqual(content, .none)
    }

    func testComposeContent_noneSelectionRendersNothing() {
        let content = TranscriptDetailComposeStack.content(
            for: .none, draftSessionId: nil)
        XCTAssertEqual(content, .none)
    }

    func testComposeContent_historySessionRoutesToChat() {
        let content = TranscriptDetailComposeStack.content(
            for: .session("session-abc"), draftSessionId: nil)
        XCTAssertEqual(content, .chat(sessionId: "session-abc"))
    }

    func testComposeContent_newSessionWithDraftRoutesToCompose() {
        let content = TranscriptDetailComposeStack.content(
            for: .newSession, draftSessionId: "draft-xyz")
        XCTAssertEqual(content, .compose(draftSessionId: "draft-xyz"))
    }

    func testComposeContent_newSessionWithoutDraftRendersNothing() {
        // Briefly true at first-mount before handleSelectionChanged()
        // lazy-allocates a draftSessionId. Must NOT fabricate an id
        // for `ChatRestingBar` — that's exactly the class of mistake
        // (treating a placeholder as a real session id) that this
        // typed-selection refactor is fixing.
        let content = TranscriptDetailComposeStack.content(
            for: .newSession, draftSessionId: nil)
        XCTAssertEqual(content, .none)
    }

    #if DEBUG
    func testComposeContent_demoSelectionsRenderNoInputChrome() {
        for kind in DemoKind.allCases {
            let content = TranscriptDetailComposeStack.content(
                for: .demo(kind), draftSessionId: nil)
            XCTAssertEqual(content, .none, "demo(.\(kind.rawValue)) should not render input chrome")
        }
    }
    #endif

    // MARK: - Side-branch routing

    func testSideBranch_archiveSelectionMountsArchiveBranch() {
        XCTAssertEqual(
            TranscriptDetailViewController.sideBranchKind(for: .archive),
            .archive)
    }

    func testSideBranch_chatSelectionsMountNoSideBranch() {
        XCTAssertNil(TranscriptDetailViewController.sideBranchKind(for: .none))
        XCTAssertNil(TranscriptDetailViewController.sideBranchKind(for: .newSession))
        XCTAssertNil(
            TranscriptDetailViewController.sideBranchKind(for: .session("session-abc")))
    }

    #if DEBUG
    func testSideBranch_demoSelectionsMountDemoBranch() {
        for kind in DemoKind.allCases {
            XCTAssertEqual(
                TranscriptDetailViewController.sideBranchKind(for: .demo(kind)),
                .demo(kind),
                "demo(.\(kind.rawValue)) should mount the matching demo side branch")
        }
    }
    #endif

    // MARK: - Cross-check via MainSelectionModel derived properties

    func testEffectiveSessionId_isNilForTabsAndArchive() {
        let model = MainSelectionModel()
        model.draftSessionId = "draft-1"

        model.selection = .none
        XCTAssertNil(model.effectiveSessionId)

        model.selection = .archive
        XCTAssertNil(model.effectiveSessionId)

        #if DEBUG
        model.selection = .demo(.transcript)
        XCTAssertNil(model.effectiveSessionId)
        #endif
    }

    func testEffectiveSessionId_resolvesNewSessionToDraft() {
        let model = MainSelectionModel()
        model.selection = .newSession
        model.draftSessionId = "draft-1"
        XCTAssertEqual(model.effectiveSessionId, "draft-1")
    }

    func testEffectiveSessionId_resolvesHistorySessionDirectly() {
        let model = MainSelectionModel()
        model.selection = .session("session-abc")
        XCTAssertEqual(model.effectiveSessionId, "session-abc")
    }

    func testIsComposeMode_onlyTrueForNewSession() {
        let model = MainSelectionModel()

        model.selection = .newSession
        XCTAssertTrue(model.isComposeMode)

        model.selection = .session("x")
        XCTAssertFalse(model.isComposeMode)

        model.selection = .archive
        XCTAssertFalse(model.isComposeMode)

        model.selection = .none
        XCTAssertFalse(model.isComposeMode)
    }
}
