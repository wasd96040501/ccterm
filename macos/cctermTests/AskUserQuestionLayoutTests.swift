import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// CI-gate (non-snapshot) measurement + focus tests for the AskUserQuestion
/// wizard's host-sizing containment (§4.5-4 / R1) and first-responder ownership
/// (§4.5-1 / §4.5-3 / R4), driven through the REAL production surface:
/// `ChatSessionViewController.present(sessionId:)` → `permissionCardController`
/// mounts the wizard, and the wizard's own `cancelOperation` / `engageOther`
/// paths.
///
/// Parallel-safe per `cctermTests/CLAUDE.md`: in-memory repository, fresh
/// manager, unique temp draft dir, suite-scoped `UserDefaults`, no `.shared` /
/// `NotificationCenter.default` / `sleep` — runloop drains + predicate waits.
@MainActor
final class AskUserQuestionLayoutTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// ≥ 1100×760 so a partial host collapse can't hide under a min clamp
    /// (`cctermTests/CLAUDE.md` host-sizing gate rule).
    private static let windowSize = CGSize(width: 1100, height: 760)

    // MARK: - Fixture (real chat VC mounted in an offscreen window)

    private struct Fixture {
        let chatVC: ChatSessionViewController
        let manager: SessionManager
        let window: NSWindow
        let sessionId: String
    }

    private func makeFixture() -> Fixture {
        let repo = InMemorySessionRepository()
        let sid = UUID().uuidString
        repo.save(
            SessionRecord(sessionId: sid, title: "S", cwd: "/tmp/aukq", status: .created))
        let manager = SessionManager(
            repository: repo, cliClientFactory: { _ in FakeCLIClient() })

        let suite = "ccterm-aukq-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let recentProjects = RecentProjectsStore(defaults: defaults)
        let syntaxEngine = SyntaxHighlightEngine()
        let draftDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-aukq-\(UUID().uuidString)", isDirectory: true)
        let inputDraftStore = InputDraftStore(directory: draftDir, debounceInterval: 0.05)

        let model = MainSelectionModel()
        let context = DetailContext(
            model: model,
            sessionManager: manager,
            recentProjects: recentProjects,
            inputDraftStore: inputDraftStore,
            syntaxEngine: syntaxEngine)
        let chatVC = ChatSessionViewController(context: context)

        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -30_000, y: -30_000), size: Self.windowSize),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01

        let container = NSView(frame: NSRect(origin: .zero, size: Self.windowSize))
        window.contentView = container
        window.ccterm_orderFrontForTesting()

        chatVC.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(chatVC.view)
        NSLayoutConstraint.activate([
            chatVC.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            chatVC.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            chatVC.view.topAnchor.constraint(equalTo: container.topAnchor),
            chatVC.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.layoutSubtreeIfNeeded()

        addTeardownBlock {
            chatVC.prepareForRemoval()
            window.contentView = nil
            window.close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: draftDir)
        }

        return Fixture(chatVC: chatVC, manager: manager, window: window, sessionId: sid)
    }

    private func drainMainLoop(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    @discardableResult
    private func waitUntil(timeout: TimeInterval = 2.0, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
            drainMainLoop(seconds: 0.01)
        }
        return predicate()
    }

    /// Seed an AskUserQuestion pending permission with `optionCount` options.
    /// The `respond` closure pops the entry (mirroring the production CLI sink)
    /// so a deny/submit through `session.respond` actually clears the queue.
    @discardableResult
    private func seedAskUserQuestion(
        _ session: ccterm.Session, requestId: String, optionCount: Int
    ) -> String {
        guard case .active(let runtime) = session.phase else {
            XCTFail("expected an active session")
            return requestId
        }
        let options = (0..<optionCount).map { ["label": "opt\($0)"] }
        let request = PermissionRequest.makePreview(
            requestId: requestId, toolName: "AskUserQuestion",
            input: ["questions": [["question": "Pick one", "options": options]]])
        runtime.pendingPermissions.append(
            PendingPermission(
                id: requestId, request: request,
                respond: { [weak runtime] _ in
                    runtime?.pendingPermissions.removeAll { $0.id == requestId }
                }))
        return requestId
    }

    /// Mount the chat VC, seed an AskUserQuestion card with `optionCount`
    /// options, wait for it to mount, settle layout, and return the chat VC's
    /// `restingBarHost.fittingSize.height`, the full-pane card host's
    /// `fittingSize.height`, and the mounted wizard root's `intrinsicContentSize`.
    private func sampleContainment(
        optionCount: Int
    ) async -> (
        barHeight: CGFloat, cardHostHeight: CGFloat, wizardIntrinsic: CGSize
    ) {
        let fx = makeFixture()
        fx.chatVC.present(sessionId: fx.sessionId)
        let session = fx.manager.session(fx.sessionId)!
        seedAskUserQuestion(session, requestId: "perm-\(optionCount)", optionCount: optionCount)
        let mounted = await waitUntil {
            fx.chatVC.permissionCardController.currentCard?.askUserQuestionController != nil
        }
        XCTAssertTrue(mounted, "the AskUserQuestion wizard card should mount")
        fx.chatVC.view.layoutSubtreeIfNeeded()
        let wizard = fx.chatVC.permissionCardController.currentCard?.askUserQuestionController
        return (
            fx.chatVC.restingBarHost.fittingSize.height,
            fx.chatVC.permissionCardHost.fittingSize.height,
            wizard?.view.intrinsicContentSize ?? CGSize(width: -1, height: -1)
        )
    }

    // MARK: - §4.5-4 / R1 — intrinsic-height containment

    /// BLOCKER: growing the wizard 2→6 options must NOT change the resting bar
    /// host's fitting height (the wizard's per-question growth flows up into the
    /// full-pane card host's slack, never pumps the bottom-anchored bar). The
    /// load-bearing facts (per the test-realness review): the mounted wizard
    /// root publishes `intrinsicContentSize == .zero` and the full-pane card
    /// host publishes `fittingSize.height ≤ 1` for BOTH the 2- and 6-option
    /// mounts — that is what actually gates R1 (the bar-height equality is a
    /// secondary sanity check, since the two sibling hosts are structurally
    /// independent).
    func testWizardGrowthDoesNotPumpBarHeight() async throws {
        let two = await sampleContainment(optionCount: 2)
        let six = await sampleContainment(optionCount: 6)

        // The discriminating R1 facts, asserted for BOTH mounts.
        XCTAssertEqual(
            two.wizardIntrinsic, .zero,
            "the wizard root must publish intrinsicContentSize == .zero (R1)")
        XCTAssertEqual(
            six.wizardIntrinsic, .zero,
            "the wizard root must publish intrinsicContentSize == .zero even at 6 options (R1)")
        XCTAssertLessThanOrEqual(
            two.cardHostHeight, 1,
            "the full-pane card host publishes fittingSize.height ≤ 1 at 2 options (R1)")
        XCTAssertLessThanOrEqual(
            six.cardHostHeight, 1,
            "the full-pane card host publishes fittingSize.height ≤ 1 at 6 options (R1)")

        // Secondary sanity check (NOT the R1 gate — restingBarHost is a
        // structurally-independent sibling of permissionCardHost): the bar's
        // fitting height is unchanged by the wizard growth.
        XCTAssertEqual(
            two.barHeight, six.barHeight, accuracy: 0.5,
            "growing the AskUserQuestion wizard 2→6 options must not change "
                + "restingBarHost.fittingSize.height (§4.5-4)")
    }

    // MARK: - §4.5-1 / R4 — Esc over a focused input bar

    /// FOCUS gate: with the input bar focused, mount the wizard, then fire
    /// `cancelOperation` at the wizard root → `onCancel` runs (the permission is
    /// denied). Asserts the wizard root holds first responder over the
    /// click-through overlay and Esc reaches it.
    func testEscOverFocusedInputBar() async throws {
        let fx = makeFixture()
        fx.chatVC.present(sessionId: fx.sessionId)
        let session = fx.manager.session(fx.sessionId)!

        // Focus the input bar's text view first (the contended responder).
        let textView = fx.chatVC.inputBarController.barView.textView
        fx.window.makeFirstResponder(textView)

        seedAskUserQuestion(session, requestId: "perm-esc", optionCount: 2)
        let mounted = await waitUntil {
            fx.chatVC.permissionCardController.currentCard?.askUserQuestionController != nil
        }
        XCTAssertTrue(mounted)
        let wizard = try XCTUnwrap(
            fx.chatVC.permissionCardController.currentCard?.askUserQuestionController)

        // The wizard root should now hold first responder (mount drove the input
        // bar to resign + made the wizard root first responder, §4.5-1).
        XCTAssertTrue(
            fx.window.firstResponder === wizard.view,
            "the wizard root should hold first responder after mount")

        // Fire Esc at the wizard root → onCancel → deny → the pending clears.
        wizard.view.cancelOperation(nil)
        let denied = await waitUntil { session.pendingPermissions.isEmpty }
        XCTAssertTrue(denied, "cancelOperation at the wizard root should deny the request")
    }

    // MARK: - §4.5-3 — engage Other keeps first responder synchronously

    /// FOCUS gate: engaging Other makes the Other field first responder
    /// SYNCHRONOUSLY (no async hop) — after one runloop tick the field is still
    /// the window's first responder (forbids an async re-assert stealing it,
    /// §4.5-3).
    func testEngageOtherThenDrainTickKeepsFieldFirstResponder() async throws {
        let fx = makeFixture()
        fx.chatVC.present(sessionId: fx.sessionId)
        let session = fx.manager.session(fx.sessionId)!
        seedAskUserQuestion(session, requestId: "perm-other", optionCount: 2)
        let mounted = await waitUntil {
            fx.chatVC.permissionCardController.currentCard?.askUserQuestionController != nil
        }
        XCTAssertTrue(mounted)
        let wizard = try XCTUnwrap(
            fx.chatVC.permissionCardController.currentCard?.askUserQuestionController)

        wizard.model.engageOther()
        // The rebuild ran synchronously off `engageOther`; the Other field is now
        // first responder.
        let other = try XCTUnwrap(wizard.otherRowForTesting)
        let fieldEditor = other.editingField.currentEditor()
        XCTAssertNotNil(fieldEditor, "the Other field should be editing (have a field editor)")
        XCTAssertTrue(
            fx.window.firstResponder === fieldEditor,
            "the Other field's editor should be first responder immediately after engage")

        // Drain one runloop tick — the field must STILL be first responder (no
        // async re-assert stole it).
        drainMainLoop(seconds: 0.05)
        XCTAssertTrue(
            fx.window.firstResponder === other.editingField.currentEditor(),
            "after one runloop tick the Other field must still be first responder (§4.5-3)")
    }

    // MARK: - Parity BLOCKER — typing into Other doesn't clobber/collapse

    /// BLOCKER regression gate: type multiple characters into the Other field
    /// through the REAL `controlTextDidChange → commitOtherText` delegate path
    /// and assert the field (a) keeps its cumulative text, (b) stays the SAME
    /// view (no per-keystroke rebuild destroyed + recreated it), (c) stays in
    /// the editing form holding first responder, and (d) `model.otherText`
    /// equals the full typed string. The original bug recreated the focused
    /// `NSTextField` on every keystroke (empty field, lost focus, text
    /// replaced not appended) — this fails hard against that.
    func testTypingOtherKeepsTextAndFocusNoRebuild() async throws {
        let fx = makeFixture()
        fx.chatVC.present(sessionId: fx.sessionId)
        let session = fx.manager.session(fx.sessionId)!
        seedAskUserQuestion(session, requestId: "perm-type", optionCount: 2)
        let mounted = await waitUntil {
            fx.chatVC.permissionCardController.currentCard?.askUserQuestionController != nil
        }
        XCTAssertTrue(mounted)
        let wizard = try XCTUnwrap(
            fx.chatVC.permissionCardController.currentCard?.askUserQuestionController)

        wizard.model.engageOther()
        let row = try XCTUnwrap(wizard.otherRowForTesting)
        let field = row.editingField
        XCTAssertTrue(row.isShowingEditingField, "engage shows the editing field")

        // Type "hello" one character at a time through the field editor — the
        // REAL `controlTextDidChange` path (not `model.commitOtherText`).
        let editor = try XCTUnwrap(field.currentEditor())
        for ch in "hello" {
            editor.insertText(String(ch))
        }

        // The SAME row + field survive every keystroke (no rebuild).
        XCTAssertTrue(
            wizard.otherRowForTesting === row,
            "the Other row must be the SAME identity across typing (no per-keystroke rebuild)")
        XCTAssertTrue(row.isShowingEditingField, "the field stays in the editing form")
        XCTAssertEqual(field.stringValue, "hello", "the field retains the cumulative typed text")
        XCTAssertEqual(wizard.model.otherText, "hello", "model.otherText is the full typed string")
        XCTAssertTrue(wizard.model.confirmEnabled, "non-empty Other enables Confirm")
        XCTAssertTrue(
            fx.window.firstResponder === field.currentEditor(),
            "the field stays first responder while typing (no focus churn)")

        // Drain a tick — still intact (no async re-assert / deferred rebuild).
        drainMainLoop(seconds: 0.05)
        XCTAssertEqual(field.stringValue, "hello")
        XCTAssertTrue(fx.window.firstResponder === field.currentEditor())
    }

    // MARK: - §4.5-1 — Esc cancels while the Other field is editing

    /// FOCUS gate: with the Other field first responder, Esc must still cancel
    /// the wizard (focus-independent, matching the SwiftUI `.cancelAction`).
    /// Drives the field editor's `cancelOperation:` → the row's
    /// `control(_:textView:doCommandBy:)` → `onCancel` → deny.
    func testEscWhileEditingOtherCancels() async throws {
        let fx = makeFixture()
        fx.chatVC.present(sessionId: fx.sessionId)
        let session = fx.manager.session(fx.sessionId)!
        seedAskUserQuestion(session, requestId: "perm-esc-other", optionCount: 2)
        let mounted = await waitUntil {
            fx.chatVC.permissionCardController.currentCard?.askUserQuestionController != nil
        }
        XCTAssertTrue(mounted)
        let wizard = try XCTUnwrap(
            fx.chatVC.permissionCardController.currentCard?.askUserQuestionController)

        wizard.model.engageOther()
        let row = try XCTUnwrap(wizard.otherRowForTesting)
        let editor = try XCTUnwrap(row.editingField.currentEditor())
        XCTAssertTrue(
            fx.window.firstResponder === editor,
            "the Other field editor holds first responder before Esc")

        // Esc routes through the field editor's `doCommand(by:)` → the field's
        // delegate `control(_:textView:doCommandBy: cancelOperation:)` → the
        // row's cancel handler → onCancel → deny. This is the exact path AppKit
        // takes when Esc is pressed in the field editor.
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        let denied = await waitUntil { session.pendingPermissions.isEmpty }
        XCTAssertTrue(
            denied, "Esc while editing the Other field should cancel/deny the request")
    }

    // MARK: - §4.5-1 / R4 — window-arrival focus retry (pre-window mount)

    /// A wizard VC whose `view` is added to a container BEFORE the container is
    /// windowed must acquire first responder once the window arrives — the
    /// production `WizardRootView.viewDidMoveToWindow` retry (a
    /// `makeFirstResponder` before the host is windowed is a silent no-op).
    /// Drives the real VC directly (its only init is the production one).
    func testWizardAcquiresFocusWhenWindowArrives() throws {
        var cancels = 0
        let request = PermissionRequest.makePreview(
            requestId: "perm-prewindow", toolName: "AskUserQuestion",
            input: ["questions": [["question": "Pick one", "options": [["label": "a"]]]]])
        let wizard = AskUserQuestionCardViewController(
            request: request, onSubmit: { _ in }, onCancel: { cancels += 1 })

        // Mount the view in a NON-windowed container first.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        wizard.view.frame = container.bounds
        container.addSubview(wizard.view)
        wizard.viewDidAppear()  // pre-window: makeFirstResponder is a silent no-op
        XCTAssertNil(
            wizard.view.window, "the wizard view is not yet in a window")

        // Now attach the container to a window — the root's viewDidMoveToWindow
        // retry should acquire first responder.
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -30_000, y: -30_000), size: Self.windowSize),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        window.contentView = container
        window.ccterm_orderFrontForTesting()
        addTeardownBlock {
            wizard.prepareForRemoval()
            window.contentView = nil
            window.close()
        }

        XCTAssertTrue(
            window.firstResponder === wizard.view,
            "the wizard root should take first responder once its host is windowed (§4.5-1/R4)")

        // And Esc reaches it.
        wizard.view.cancelOperation(nil)
        XCTAssertEqual(cancels, 1, "Esc at the wizard root cancels after window-arrival focus")
    }

    // MARK: - MAJOR parity — option row grows for a 2-line description

    /// An option row carrying a long (2-line) description must grow PAST 36pt
    /// (SwiftUI `.padding(.vertical, 8).frame(minHeight: rowHeight)`), while a
    /// single-line row stays at the 36pt floor — the row uses `>= rowHeight`,
    /// not a fixed `== rowHeight` that would clip the second description line.
    func testOptionRowGrowsForTwoLineDescription() {
        let width: CGFloat = 320

        let single = AskOptionRowView(label: "Short", description: nil, selected: false)
        single.translatesAutoresizingMaskIntoConstraints = false
        single.widthAnchor.constraint(equalToConstant: width).isActive = true
        single.layoutSubtreeIfNeeded()
        let singleHeight = single.fittingSize.height
        XCTAssertEqual(
            singleHeight, AskUserQuestionLayout.rowHeight, accuracy: 0.5,
            "a single-line option row stays at the 36pt floor")

        let longDescription = String(repeating: "This is a fairly long description. ", count: 4)
        let multi = AskOptionRowView(
            label: "Pick me", description: longDescription, selected: false)
        multi.translatesAutoresizingMaskIntoConstraints = false
        multi.widthAnchor.constraint(equalToConstant: width).isActive = true
        multi.layoutSubtreeIfNeeded()
        let multiHeight = multi.fittingSize.height
        XCTAssertGreaterThan(
            multiHeight, AskUserQuestionLayout.rowHeight,
            "a 2-line-description option row grows past the 36pt floor (not clipped)")
    }
}
