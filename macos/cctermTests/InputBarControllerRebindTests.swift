import AppKit
import Observation
import XCTest

@testable import ccterm

/// CI-gate logic/measurement tests (NOT a `*SnapshotTests` file → runs on the
/// default suite as the merge gate) for the **Phase-1 integration** of the
/// pure-AppKit `InputBarController` into `ChatSessionViewController`
/// (migration plan §3 / §4.0 / §4.1-1/2). Every test drives the REAL
/// production surface — `ChatSessionViewController.present(sessionId:)` (which
/// the router calls), the real once-built `inputBarController`, its real
/// `InputNSTextView` + delegate path, the real `CompletionState` — and asserts
/// on the production objects' observable geometry / state. No test-only
/// production seams beyond the access-modifier accessors
/// (`restingBarHost` / `inputBarController`) the `HostedComponentCenteringTests`
/// gate already relies on.
///
/// What it locks in:
///   - **rebind-in-place is bar-invariant** — `present(A)` then `present(B)`
///     leaves `restingBarHost.frame` identical (the constraints never change on
///     a session switch, plan §4.0 — the reason `attachSession`'s single-width
///     typeset pass stays bar-invariant), and resets text/attachments/
///     completion to empty across the switch (the AppKit analogue of the
///     deleted SwiftUI `.id(sid)`).
///   - **multi-line height tracking** — feeding multi-line text into the real
///     text view grows `restingBarHost.fittingSize.height` (the nested
///     `intrinsicContentSize` re-sum, plan §4.1-1 / R7).
///   - **scrim-cutout stability** — the attach/pill rects the bar reports
///     (converted to `inputBarController.view`) stay STABLE when the completion
///     popup opens/closes (the popup grows the bar upward; attach/pill are
///     bottom-anchored, plan §4.1-2 / R6).
@MainActor
final class InputBarControllerRebindTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Fixture (mirrors HostedComponentCenteringTests.makeFixture)

    private struct Fixture {
        let model: MainSelectionModel
        let manager: SessionManager
        let vc: ChatSessionViewController
        let sessionIdA: String
        let sessionIdB: String
    }

    private func makeFixture() -> Fixture {
        let repo = InMemorySessionRepository()
        let sidA = UUID().uuidString
        let sidB = UUID().uuidString
        repo.save(
            SessionRecord(sessionId: sidA, title: "A", cwd: "/tmp/rebind-a", status: .created))
        repo.save(
            SessionRecord(sessionId: sidB, title: "B", cwd: "/tmp/rebind-b", status: .created))
        let manager = SessionManager(
            repository: repo, cliClientFactory: { _ in FakeCLIClient() })

        let defaultsSuite = "ccterm-rebind-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: defaultsSuite) }
        let recentProjects = RecentProjectsStore(defaults: defaults)
        let syntaxEngine = SyntaxHighlightEngine()
        let draftDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-rebind-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: draftDir) }
        let inputDraftStore = InputDraftStore(directory: draftDir, debounceInterval: 0.05)

        let model = MainSelectionModel()
        let vc = ChatSessionViewController(
            context: DetailContext(
                model: model,
                sessionManager: manager,
                recentProjects: recentProjects,
                inputDraftStore: inputDraftStore,
                syntaxEngine: syntaxEngine))

        return Fixture(
            model: model, manager: manager, vc: vc, sessionIdA: sidA, sessionIdB: sidB)
    }

    // MARK: - Runloop pump

    private func drainMainLoop(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
    }

    private func settle(iterations: Int = 12) async {
        for _ in 0..<iterations {
            try? await Task.sleep(for: .milliseconds(30))
            drainMainLoop(seconds: 0.02)
        }
    }

    /// Mount the VC pinned edge-to-edge in a size-locked offscreen window so the
    /// bar host gets a real production-style frame.
    private func mount(
        _ fx: Fixture, size: CGSize = CGSize(width: 1100, height: 800)
    ) async
        -> NSWindow
    {
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        window.minSize = size
        window.maxSize = size

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = container
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: size.width),
            container.heightAnchor.constraint(equalToConstant: size.height),
        ])
        window.ccterm_orderFrontForTesting()

        fx.vc.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(fx.vc.view)
        NSLayoutConstraint.activate([
            fx.vc.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            fx.vc.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            fx.vc.view.topAnchor.constraint(equalTo: container.topAnchor),
            fx.vc.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.layoutSubtreeIfNeeded()
        await settle()
        return window
    }

    // MARK: - Rebind is bar-invariant (plan §4.0)

    func testRebindKeepsBarHostFrameIdentical() async throws {
        let fx = makeFixture()
        let window = await mount(fx)
        defer {
            window.contentView = nil
            window.close()
        }

        // Present A (the router's path) — also rebinds the bar.
        fx.vc.present(sessionId: fx.sessionIdA)
        await settle()
        fx.vc.view.layoutSubtreeIfNeeded()
        let frameA = fx.vc.restingBarHost.frame

        // Switch to B — rebind in place, constraints invariant.
        fx.vc.present(sessionId: fx.sessionIdB)
        await settle()
        fx.vc.view.layoutSubtreeIfNeeded()
        let frameB = fx.vc.restingBarHost.frame

        XCTAssertEqual(
            frameA.width, frameB.width, accuracy: 0.5,
            "Bar host width changed across rebind (\(frameA.width) → \(frameB.width)) — "
                + "the regime-B constraints must be invariant on a session switch.")
        XCTAssertEqual(
            frameA.height, frameB.height, accuracy: 0.5,
            "Bar host height changed across rebind (\(frameA.height) → \(frameB.height)) — "
                + "a fresh empty bar must report the same intrinsic height.")
        XCTAssertEqual(
            frameA.origin.x, frameB.origin.x, accuracy: 0.5,
            "Bar host x shifted across rebind — centering must be invariant.")
        XCTAssertEqual(
            frameA.origin.y, frameB.origin.y, accuracy: 0.5,
            "Bar host y shifted across rebind — bottom-anchor must be invariant.")
    }

    func testRebindResetsTextAttachmentsAndCompletion() async throws {
        let fx = makeFixture()
        let window = await mount(fx)
        defer {
            window.contentView = nil
            window.close()
        }

        fx.vc.present(sessionId: fx.sessionIdA)
        await settle()

        // Dirty the bar through the real text view + completion. The fixture's
        // saved records carry a non-nil cwd, which would route a typed "/" down
        // `SlashCommandStore.shared` (a process-wide singleton that spawns a
        // temp-CLI subprocess + installs FSEvents — forbidden in a parallel
        // test). Rebind the bar in place to a FOLDER-LESS id first (a fresh UUID
        // with no record → `prepareDraftSession` returns a `.draft` whose
        // `cwd == nil`), so the slash rule takes the synchronous in-process
        // `.noDirectory` branch and `isActive` reports true without any
        // subprocess — the same pattern `InputBarControllerTests` uses.
        let controller = fx.vc.inputBarController!
        let folderlessId = UUID().uuidString
        controller.rebind(sessionId: folderlessId)
        await settle()
        XCTAssertNil(
            fx.manager.prepareDraftSession(folderlessId).cwd,
            "fixture precondition: the bound draft session must have a nil cwd "
                + "so the slash rule takes the in-process .noDirectory branch.")
        let tv = controller.barView.textView
        window.makeFirstResponder(tv)
        // A LEADING "/" both makes the text non-empty AND activates the slash
        // completion: `SlashCommandTriggerRule` only matches when the slash is at
        // cursorLocation 1 (the first char). With `cwd == nil` it takes the
        // synchronous in-process `.noDirectory` branch, so no subprocess fires.
        tv.insertText("/", replacementRange: tv.selectedRange())
        await settle(iterations: 4)
        XCTAssertFalse(tv.string.isEmpty, "fixture: text should be non-empty before switch")
        XCTAssertTrue(
            controller.completion.isActive,
            "fixture: a leading '/' on a folder-less session should activate completion.")

        // Switch to B (the router path) — rebind resets everything in place.
        fx.vc.present(sessionId: fx.sessionIdB)
        await settle()

        XCTAssertEqual(
            controller.barView.textView.string, "",
            "Text must reset to empty across a session switch (the `.id(sid)` analogue).")
        XCTAssertTrue(
            controller.attachments.isEmpty,
            "Attachments must reset to empty across a session switch.")
        XCTAssertFalse(
            controller.completion.isActive,
            "Completion must be dismissed across a session switch.")
        XCTAssertEqual(
            controller.boundSessionId, fx.sessionIdB,
            "The bar must be bound to the new session id after rebind.")
    }

    // MARK: - .none clears the bar (plan §4.0)

    func testPresentNoneClearsTheBar() async throws {
        let fx = makeFixture()
        let window = await mount(fx)
        defer {
            window.contentView = nil
            window.close()
        }

        fx.vc.present(sessionId: fx.sessionIdA)
        await settle()
        let controller = fx.vc.inputBarController!
        let tv = controller.barView.textView
        tv.insertText("typed", replacementRange: tv.selectedRange())
        await settle(iterations: 3)

        fx.vc.present(sessionId: nil)
        await settle(iterations: 3)

        XCTAssertEqual(
            controller.barView.textView.string, "",
            "`.none` must clear the bar text (the EmptyView collapse analogue).")
        XCTAssertNil(
            controller.boundSessionId,
            "`.none` must unbind the bar from any session.")
    }

    // MARK: - Multi-line height tracking (plan §4.1-1 / R7)

    func testMultiLineTextGrowsBarHost() async throws {
        let fx = makeFixture()
        let window = await mount(fx)
        defer {
            window.contentView = nil
            window.close()
        }

        fx.vc.present(sessionId: fx.sessionIdA)
        await settle()
        fx.vc.view.layoutSubtreeIfNeeded()
        let oneLineHeight = fx.vc.restingBarHost.fittingSize.height

        let controller = fx.vc.inputBarController!
        let tv = controller.barView.textView
        tv.insertText("line1\nline2\nline3\nline4\nline5\nline6", replacementRange: tv.selectedRange())
        await settle(iterations: 4)
        fx.vc.view.layoutSubtreeIfNeeded()
        let multiLineHeight = fx.vc.restingBarHost.fittingSize.height

        XCTAssertGreaterThan(
            multiLineHeight, oneLineHeight + 20,
            "Multi-line text must grow the bar host's fittingSize.height "
                + "(\(oneLineHeight) → \(multiLineHeight)) — the nested intrinsicContentSize "
                + "re-sum (R7) failed to propagate through the AppKit container.")
    }

    // MARK: - Scrim-cutout stability across popup open/close (plan §4.1-2 / R6)

    func testScrimCutoutsStableAcrossCompletionPopup() async throws {
        let fx = makeFixture()
        let window = await mount(fx)
        defer {
            window.contentView = nil
            window.close()
        }

        fx.vc.present(sessionId: fx.sessionIdA)
        await settle()
        fx.vc.view.layoutSubtreeIfNeeded()

        let controller = fx.vc.inputBarController!
        // Rebind in place to a FOLDER-LESS id (fresh UUID, no record → nil cwd)
        // so the leading "/" below activates completion via the synchronous
        // in-process `.noDirectory` branch — NOT `SlashCommandStore.shared`
        // (which would spawn a temp-CLI subprocess + FSEvents and break parallel
        // safety). The bar's geometry (attach/pill rects, anchored to
        // `inputBarController.view`) is independent of which session is bound, so
        // the cutout-stability assertion is unaffected by the folder-less rebind.
        let folderlessId = UUID().uuidString
        controller.rebind(sessionId: folderlessId)
        await settle()
        XCTAssertNil(
            fx.manager.prepareDraftSession(folderlessId).cwd,
            "fixture precondition: the bound draft session must have a nil cwd "
                + "so the slash rule takes the in-process .noDirectory branch.")
        fx.vc.view.layoutSubtreeIfNeeded()

        let bar = controller.barView!

        // Capture the rects production REPORTS (via `onAttachRect`/`onPillRect`,
        // converted to the controller's view — the scrim anchor) BEFORE the
        // popup. `layout()` runs `reportScrimRects()`, which stores the reported
        // rects on the bar (the production source of truth — no re-derivation).
        bar.layout()
        let attachBefore = bar.lastReportedAttachRect
        let pillBefore = bar.lastReportedPillRect
        XCTAssertFalse(
            attachBefore.isNull, "fixture: the bar must have reported an attach rect.")
        XCTAssertFalse(
            pillBefore.isNull, "fixture: the bar must have reported a pill rect.")

        // Open the completion popup via a leading "/" (cwd == nil → in-process
        // `.noDirectory` branch → isActive true; the popup reserves height and
        // grows the bar UPWARD).
        let tv = bar.textView
        window.makeFirstResponder(tv)
        tv.insertText("/", replacementRange: tv.selectedRange())
        await settle(iterations: 4)
        XCTAssertTrue(
            controller.completion.isActive,
            "fixture: a leading '/' should activate completion so the popup grows the bar.")
        fx.vc.view.layoutSubtreeIfNeeded()
        bar.layout()

        let attachDuring = bar.lastReportedAttachRect
        let pillDuring = bar.lastReportedPillRect

        // The attach button + bottom pill row are bottom-anchored, so the popup
        // growing the bar upward must NOT move them (plan §4.1-2 / R6).
        XCTAssertEqual(
            attachBefore.minY, attachDuring.minY, accuracy: 0.5,
            "Attach cutout moved when the popup opened (\(attachBefore) → \(attachDuring)) — "
                + "the attach button must stay bottom-anchored.")
        XCTAssertEqual(
            attachBefore.height, attachDuring.height, accuracy: 0.5,
            "Attach cutout height changed when the popup opened.")
        XCTAssertEqual(
            pillBefore.minY, pillDuring.minY, accuracy: 0.5,
            "Pill cutout moved when the popup opened (\(pillBefore) → \(pillDuring)) — "
                + "the bottom pill row must stay bottom-anchored.")
        XCTAssertEqual(
            pillBefore.height, pillDuring.height, accuracy: 0.5,
            "Pill cutout height changed when the popup opened — only the BOTTOM row "
                + "is cut, independent of the popup's height.")
    }
}
