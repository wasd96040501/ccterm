import XCTest

@testable import ccterm

/// Pins the `MainSelection` → session-routing invariants that the chat /
/// compose / draft surfaces derive from `MainSelectionModel` directly:
/// `effectiveSessionId` (which session, if any, a selection resolves to) and
/// `isComposeMode` (whether the New Session compose surface is showing).
///
/// These assertions used to live alongside the `ChatComposeStack.content(for:)`
/// routing tests, but D8 deleted that enum (its only code consumer was the
/// retired SwiftUI `PermissionCardOverlay`; the AppKit `PermissionCardController`
/// re-derives the `Session` from the `sessionId` the router hands
/// `present(sessionId:)`). The enum-routing tests went with it; these
/// production-surface tests survive verbatim on `MainSelectionModel`.
///
/// Router-level mount/unmount invariants live in `DetailRouterContainmentTests`.
@MainActor
final class MainSelectionModelRoutingTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

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
