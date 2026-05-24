import XCTest

@testable import ccterm

/// Pins the routing decision that translates `MainSelection` →
/// `ChatComposeStack.content(for:draftSessionId:)`,
/// which is what the (still always-mounted) input-bar overlay
/// inside `ChatSessionViewController` renders. The invariants:
/// `.archive` / `.demo` / `.none` collapse to `.none`, so no input
/// chrome floats on top of pages where the VC is unexpectedly
/// mounted; `.newSession` with a draft renders the compose card;
/// `.session(_)` renders the chat resting bar.
///
/// Pre-fix, the `.archive` branch fell through to
/// `ChatRestingBar(sessionId: "__archive__")`, mounting a SwiftUI
/// input bar that swallowed clicks on the Archive page's Unarchive
/// button (#222).
///
/// `DetailRouterViewController` now routes `.archive` and `.demo(_)`
/// away from `ChatSessionViewController` entirely, so the
/// `.archive` / `.demo` content-routing assertions below are
/// belt-and-suspenders: even if the router regressed, the compose
/// stack must still not fabricate input chrome for those cases.
/// Router-level mount/unmount invariants live in
/// `DetailRouterContainmentTests`.
@MainActor
final class ChatComposeStackRoutingTests: XCTestCase {

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
        let content = ChatComposeStack.content(
            for: .archive, draftSessionId: "draft-1")
        XCTAssertEqual(content, .none)
    }

    func testComposeContent_noneSelectionRendersNothing() {
        let content = ChatComposeStack.content(
            for: .none, draftSessionId: nil)
        XCTAssertEqual(content, .none)
    }

    func testComposeContent_historySessionRoutesToChat() {
        let content = ChatComposeStack.content(
            for: .session("session-abc"), draftSessionId: nil)
        XCTAssertEqual(content, .chat(sessionId: "session-abc"))
    }

    func testComposeContent_newSessionWithDraftRoutesToCompose() {
        let content = ChatComposeStack.content(
            for: .newSession, draftSessionId: "draft-xyz")
        XCTAssertEqual(content, .compose(draftSessionId: "draft-xyz"))
    }

    func testComposeContent_newSessionWithoutDraftRendersNothing() {
        // Briefly true at first-mount before handleSelectionChanged()
        // lazy-allocates a draftSessionId. Must NOT fabricate an id
        // for `ChatRestingBar` — that's exactly the class of mistake
        // (treating a placeholder as a real session id) that this
        // typed-selection refactor is fixing.
        let content = ChatComposeStack.content(
            for: .newSession, draftSessionId: nil)
        XCTAssertEqual(content, .none)
    }

    #if DEBUG
    func testComposeContent_demoSelectionsRenderNoInputChrome() {
        for kind in DemoKind.allCases {
            let content = ChatComposeStack.content(
                for: .demo(kind), draftSessionId: nil)
            XCTAssertEqual(content, .none, "demo(.\(kind.rawValue)) should not render input chrome")
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
