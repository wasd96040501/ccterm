import AppKit
import XCTest

@testable import ccterm

/// Sample / regression test exercising the `AppKitStage` harness on a
/// **full real `MainSplitViewController`** — real `SidebarViewController`
/// + real `DetailRouterViewController` + real `SessionManager`, assembled
/// through the dependency-injected `AppState` so the production wiring runs
/// verbatim. It demonstrates the three capability classes the harness was
/// built for, against the sidebar↔transcript linkage specifically:
///
/// 1. **Layout / region** — the chat resting bar centers + width-caps
///    inside the detail pane (not the window), measured relative to its
///    container via `Geometry`.
/// 2. **Complex interaction linkage** — selecting a sidebar row drives the
///    real `model.select` write-back, the router swaps the transcript, and
///    the newly-shown transcript reflects the target session.
/// 3. **Detail-pane geometry** — the harness exposes `sidebarWidth` /
///    `detailPaneWidth` so a transcript-region assertion need not hard-code
///    the sidebar's autosaved thickness.
///
/// Not a `*SnapshotTests` file → runs on the default suite + CI as a merge
/// gate (assertion-driven, no PNG).
@MainActor
final class MainSplitLinkageTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func makeSessions() -> [AppKitStage.SessionSpec] {
        [
            AppKitStage.SessionSpec(
                title: "Alpha", blocks: AppKitStage.SessionSpec.paragraphBlocks(count: 60)),
            AppKitStage.SessionSpec(
                title: "Beta", blocks: AppKitStage.SessionSpec.paragraphBlocks(count: 8)),
        ]
    }

    /// The split lays out at the default (real main-window) size: a sidebar
    /// pane + a wider detail pane. Establishes the geometry the other tests
    /// build on, and that the harness's pane-width queries resolve.
    func testSplitPaneGeometry() async throws {
        let fx = AppKitStage.mainSplit(sessions: makeSessions(), initialIndex: 0)
        defer { fx.teardown() }
        await fx.stage.settle()

        guard let sidebarWidth = fx.stage.sidebarWidth,
            let detailPaneWidth = fx.stage.detailPaneWidth
        else {
            XCTFail("pane-width queries returned nil — not a mainSplit stage?")
            return
        }

        // Sidebar item is constrained to [220, 350]; detail must take the
        // rest of the 1200pt-wide window and dwarf the sidebar.
        XCTAssertGreaterThanOrEqual(sidebarWidth, 200, "sidebar narrower than its min thickness")
        XCTAssertGreaterThan(
            detailPaneWidth, sidebarWidth,
            "detail pane should be wider than the sidebar "
                + "(sidebar=\(sidebarWidth) detail=\(detailPaneWidth))")
    }

    /// Layout/region: the chat resting bar is centered inside the **detail
    /// pane** (its container), not the window, and never exceeds the
    /// layout-width cap. Measured relative to the host's superview so the
    /// sidebar's width is irrelevant to the assertion.
    func testRestingBarCentersInDetailPane() async throws {
        let fx = AppKitStage.mainSplit(sessions: makeSessions(), initialIndex: 0)
        defer { fx.teardown() }
        await fx.stage.settle()

        guard let chatVC = fx.stage.router?.currentChild as? ChatSessionViewController else {
            XCTFail("initial session did not mount a ChatSessionViewController")
            return
        }
        let bar = chatVC.restingBarHost!
        guard let container = bar.superview else {
            XCTFail("resting bar host has no superview")
            return
        }

        // Centered horizontally in its container, and capped to the chat
        // layout width — both measured in the container's coordinate space.
        Geometry.assertCenteredX(bar, in: container, tolerance: 1.5)
        Geometry.assertWidth(bar, atMost: BlockStyle.maxLayoutWidth + 200)
        Geometry.assertContained(bar, in: container, tolerance: 2.0)
    }

    /// Complex interaction linkage: select the second sidebar row through
    /// the **real** outline-view selection (which fires
    /// `outlineViewSelectionDidChange` → `model.select`), and verify the
    /// router swapped the transcript to the target session — observable as
    /// the new transcript's row count matching Beta's shorter block list.
    func testSidebarRowSelectionSwitchesTranscript() async throws {
        let fx = AppKitStage.mainSplit(sessions: makeSessions(), initialIndex: 0)
        defer { fx.teardown() }
        await fx.stage.settle()

        // The two sessions have distinct transcript lengths so the swap is
        // observable purely from the mounted table's row count.
        let alphaBlocks = fx.sessionManager.session(fx.sessionIds[0])?.controller.blockIds.count
        let betaBlocks = fx.sessionManager.session(fx.sessionIds[1])?.controller.blockIds.count
        XCTAssertEqual(alphaBlocks, 60)
        XCTAssertEqual(betaBlocks, 8)

        // Find the sidebar row whose node selects Beta, and drive the real
        // outline selection there.
        guard let outline = fx.stage.find(NSOutlineView.self) else {
            XCTFail("no sidebar outline view mounted")
            return
        }
        var betaRow: Int?
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? SidebarItemNode,
                node.selection == .session(fx.sessionIds[1])
            {
                betaRow = row
                break
            }
        }
        guard let betaRow else {
            XCTFail("Beta session row not found in sidebar (rows=\(outline.numberOfRows))")
            return
        }

        XCTAssertTrue(fx.stage.driver.selectSidebarRow(betaRow), "row select failed")
        await fx.stage.settle()

        // Model reflects the selection (write-back happened)...
        XCTAssertEqual(fx.model.selection, .session(fx.sessionIds[1]))
        // ...and the router swapped in Beta's transcript.
        guard let table = fx.stage.find(Transcript2TableView.self) else {
            XCTFail("no transcript table mounted after switch")
            return
        }
        XCTAssertEqual(
            table.numberOfRows, betaBlocks,
            "transcript did not switch to Beta (rows=\(table.numberOfRows), expected \(betaBlocks!))")
    }
}
