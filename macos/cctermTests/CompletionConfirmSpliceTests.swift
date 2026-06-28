import AppKit
import XCTest

@testable import ccterm

/// CI-gate logic test (NOT a `*SnapshotTests` file) for the completion CONFIRM
/// SPLICE reentrancy contract (migration plan §4.3-4, §9). Drives the REAL
/// `InputBarController` confirm path (the `keyInterceptor` closure with a
/// synthesized Return event) over the REAL `CompletionState` + REAL
/// `InputNSTextView`, and asserts the observable result of a NON-EMPTY splice:
/// the session dismisses, items empty, the text view string carries the
/// spliced replacement, the caret lands at the end of the inserted text, and
/// the double `textDidChange` + `textViewDidChangeSelection` the splice fires
/// do NOT re-trigger a fresh completion (the `isApplyingProgrammaticText`
/// guard held — no spurious second `checkTrigger`).
///
/// Parallel-safety: the bound session is ACTIVE with a populated
/// `slashCommands` list, so the slash rule takes the SYNCHRONOUS
/// `knownCommands` filter path — it never spawns a temp CLI / fzf subprocess
/// and never writes the `SlashCommandStore.shared` cache. Each test computes
/// from its OWN `slashCommands` input, so there's no observable cross-test
/// side effect on the singleton's stateless filter path.
@MainActor
final class CompletionConfirmSpliceTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private struct Fixture {
        let controller: InputBarController
        let manager: SessionManager
        let sessionId: String
    }

    /// Active-phase session (`.created` record) with a populated
    /// `slashCommands` list so the slash rule uses the synchronous filter.
    private func makeFixture() -> Fixture {
        let repo = InMemorySessionRepository()
        let sid = UUID().uuidString
        repo.save(
            SessionRecord(
                sessionId: sid, title: "Splice", cwd: "/tmp/splice", status: .created))
        let manager = SessionManager(repository: repo, cliClientFactory: { _ in FakeCLIClient() })

        let draftDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-splice-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: draftDir) }
        let store = InputDraftStore(directory: draftDir, debounceInterval: 0.05)
        let suite = "ccterm-splice-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        let controller = InputBarController(
            sessionManager: manager, inputDraftStore: store, userDefaults: defaults,
            notificationCenter: NotificationCenter(),
            onSubmit: { _, _ in })

        // Seed the active session's CLI-provided slash command list so the
        // slash rule's known-commands synchronous path fires (no subprocess).
        let session = manager.prepareDraftSession(sid)
        session.runtime?.slashCommands = [
            SlashCommand(name: "commit", description: "Create a git commit"),
            SlashCommand(name: "review", description: "Review the diff"),
        ]
        return Fixture(controller: controller, manager: manager, sessionId: sid)
    }

    private func mount(_ controller: InputBarController) -> NSWindow {
        let size = CGSize(width: 600, height: 220)
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = container
        window.ccterm_orderFrontForTesting()
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            controller.view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            controller.view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -36),
        ])
        container.layoutSubtreeIfNeeded()
        return window
    }

    private func settle(iterations: Int = 12) async {
        for _ in 0..<iterations {
            try? await Task.sleep(for: .milliseconds(30))
            let deadline = Date().addingTimeInterval(0.02)
            while Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            }
        }
    }

    // MARK: - Non-empty CLI splice: dismiss + caret-at-end + no re-trigger

    func testCliSlashConfirmSplicesAndDoesNotRetrigger() async throws {
        let fx = makeFixture()
        let window = mount(fx.controller)
        defer {
            window.contentView = nil
            window.close()
        }
        fx.controller.rebind(sessionId: fx.sessionId)
        await settle()

        let tv = fx.controller.barView.textView
        window.makeFirstResponder(tv)

        // Type "/commit" through the real delegate path so the slash session
        // arms + the synchronous known-commands provider returns /commit.
        for ch in "/commit" {
            tv.insertText(String(ch), replacementRange: tv.selectedRange())
            fx.controller.textDidChange(
                Notification(name: NSText.didChangeNotification, object: tv))
        }

        // Wait for the provider result to land. The "/commit" query is
        // NON-EMPTY, so `CompletionState.refreshQuery` routes through the
        // debounce + loading Tasks before items arrive on main; gate on the
        // ACTUAL readiness condition (a predicate), not a fixed sleep
        // (cctermTests/CLAUDE.md rule 6).
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                fx.controller.completion.isActive
                    && !fx.controller.completion.items.isEmpty
            }, object: nil)
        await fulfillment(of: [ready], timeout: 5)

        XCTAssertTrue(
            fx.controller.completion.isActive,
            "A leading '/commit' with a populated slashCommands list should activate completion.")
        XCTAssertFalse(
            fx.controller.completion.items.isEmpty,
            "The synchronous known-commands provider should have returned matches.")
        // Select the /commit row (index 0 after filtering to "commit").
        fx.controller.completion.selectedIndex = 0

        // Confirm via the key interceptor (Return, keyCode 36) — the REAL path.
        let returnEvent = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        _ = tv.onInterceptKeyDown?(returnEvent)
        await settle()

        // (a) The session dismissed; items empty.
        XCTAssertFalse(
            fx.controller.completion.isActive,
            "Confirming a CLI slash command dismisses the completion.")
        XCTAssertTrue(
            fx.controller.completion.items.isEmpty,
            "Items must be empty after confirm (both delegate callbacks early-returned "
                + "under the programmatic guard — no spurious re-trigger).")

        // (b) The text view carries the spliced replacement "/commit " (a CLI
        // command splices `/name ` so the user can type arguments).
        XCTAssertEqual(
            tv.string, "/commit ",
            "A CLI slash command splices '/name ' into the text on confirm.")

        // (c) The caret lands at the END of the inserted text (length of
        // "/commit " == 8).
        XCTAssertEqual(
            tv.selectedRange().location, 8,
            "The caret must land at the end of the spliced replacement.")
        XCTAssertEqual(tv.selectedRange().length, 0, "No selection after the splice.")

        // (d) No spurious second completion got armed by the splice's
        // double-trigger (the guard held) — completion stayed inactive.
        XCTAssertFalse(
            fx.controller.completion.isActive,
            "The splice's textDidChange + textViewDidChangeSelection must not re-arm "
                + "a fresh completion (isApplyingProgrammaticText held).")
    }
}
