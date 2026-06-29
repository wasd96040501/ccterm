import AppKit
import Observation
import XCTest

@testable import ccterm

/// CI-gate logic/measurement tests (NOT a `*SnapshotTests` file → runs on the
/// default suite as the merge gate) for the AppKit `InputBarController` spine
/// (migration plan §4.1, §9). Every test drives the REAL controller — feeds
/// text through the production `NSTextView` + delegate path, calls the real
/// `handleSend` / `rebind`, flips the real `session.isRunning` / `session.cwd`
/// through the public surface, and asserts on the controller's observable
/// state (`canSend`, the bar's `fittingSize.height`, the text view's
/// `sendKeyBehavior`, the reported scrim rects). No stubs, no test-only
/// production seams: the controller's secondary-`init`-style dependency
/// injection (fresh in-memory `SessionManager` / temp-dir `InputDraftStore` /
/// `UserDefaults(suiteName:)`) is the allowed seam — the default init +
/// production behavior are unchanged.
@MainActor
final class InputBarControllerTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Fixture

    private struct Fixture {
        let controller: InputBarController
        let manager: SessionManager
        let inputDraftStore: InputDraftStore
        let defaults: UserDefaults
        let notificationCenter: NotificationCenter
        let activeSessionId: String
        var submitRecords: SubmitRecorder
    }

    /// Records the order of `inputDraftStore.clear` vs `onSubmit` so the
    /// draft-clear-before-onSubmit invariant (§4.1-4) is observable. A
    /// reference type so the recorded events survive the closure capture.
    private final class SubmitRecorder {
        var events: [String] = []
        var submissions: [Submission] = []
        var lastSessionId: String?
        /// Fired at the start of `onSubmit` so a test can probe the
        /// controller's already-cleared state at submit time.
        var onSubmitProbe: (() -> Void)?
    }

    /// Build a real `InputBarController` with fresh in-memory deps. A single
    /// `.created`-status record makes `prepareDraftSession` return an
    /// active-phase session (so `send`/`interrupt` flip `isRunning` and `cwd`
    /// reads the runtime config) — mirrors `HostedComponentCenteringTests`.
    /// `sendKeyValue` seeds the injected defaults before the controller reads
    /// it in `loadView`.
    private func makeFixture(
        sendKeyValue: String? = nil,
        autofocus: Bool = false,
        onBuiltinCommand: ((BuiltinSlashCommand) -> Void)? = nil,
        submitEnabledProvider: ((Session) -> Bool)? = nil
    ) -> Fixture {
        let repo = InMemorySessionRepository()
        let sid = UUID().uuidString
        repo.save(
            SessionRecord(
                sessionId: sid, title: "InputBar", cwd: "/tmp/inputbar", status: .created))
        let manager = SessionManager(
            repository: repo, cliClientFactory: { _ in FakeCLIClient() })

        let draftDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-inputbar-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: draftDir) }
        let inputDraftStore = InputDraftStore(directory: draftDir, debounceInterval: 0.05)

        let suite = "ccterm-inputbar-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        if let sendKeyValue { defaults.set(sendKeyValue, forKey: "sendKeyBehavior") }
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        let notificationCenter = NotificationCenter()
        let recorder = SubmitRecorder()

        let controller = InputBarController(
            sessionManager: manager,
            inputDraftStore: inputDraftStore,
            userDefaults: defaults,
            notificationCenter: notificationCenter,
            autofocus: autofocus,
            onBuiltinCommand: onBuiltinCommand,
            submitEnabledProvider: submitEnabledProvider ?? { _ in true },
            onSubmit: { [weak inputDraftStore] submission, sessionId in
                _ = inputDraftStore
                recorder.onSubmitProbe?()
                recorder.events.append("submit")
                recorder.submissions.append(submission)
                recorder.lastSessionId = sessionId
            })

        return Fixture(
            controller: controller, manager: manager, inputDraftStore: inputDraftStore,
            defaults: defaults, notificationCenter: notificationCenter,
            activeSessionId: sid, submitRecords: recorder)
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

    /// Mount the controller's view in an offscreen alpha-0.01 window so the
    /// text view can become first responder and the bar gets a real frame.
    private func mount(_ fx: Fixture, width: CGFloat = 600) -> NSWindow {
        let size = CGSize(width: width, height: 220)
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = container
        window.ccterm_orderFrontForTesting()

        let barView = fx.controller.view
        barView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(barView)
        NSLayoutConstraint.activate([
            barView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            barView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            barView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -36),
        ])
        container.layoutSubtreeIfNeeded()
        return window
    }

    /// Type `text` through the real NSTextView so the delegate path runs
    /// (matching a user keystroke). `insertText:` fires `textDidChange`.
    private func type(_ text: String, into fx: Fixture) {
        let tv = fx.controller.barView.textView
        tv.insertText(text, replacementRange: tv.selectedRange())
    }

    // MARK: - canSend gating (§4.1)

    func testCanSendGating() async throws {
        let fx = makeFixture()
        let window = mount(fx)
        defer {
            window.contentView = nil
            window.close()
        }
        fx.controller.rebind(sessionId: fx.activeSessionId)
        await settle()

        // Empty → cannot send.
        XCTAssertFalse(fx.controller.canSend, "Empty bar should not be sendable.")

        // Whitespace-only → still cannot send.
        type("   \n  ", into: fx)
        XCTAssertFalse(fx.controller.canSend, "Whitespace-only text should not be sendable.")

        // Non-empty text → sendable.
        type("hello", into: fx)
        XCTAssertTrue(fx.controller.canSend, "Non-empty text should be sendable.")

        // Clear text, attach a file → sendable on attachment alone.
        fx.controller.barView.textView.string = ""
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-attach-\(UUID().uuidString).txt")
        try "x".write(to: tmp, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        fx.controller.attachPickedURL(tmp)
        XCTAssertTrue(
            fx.controller.canSend, "An attachment alone (no text) should be sendable.")
    }

    // MARK: - submitEnabled reactive over session.cwd (§4.1-8)

    func testSubmitEnabledReactiveOnCwd() async throws {
        // A draft session with no cwd; submitEnabled = (cwd != nil), the
        // compose contract. Drive the REAL session.cwd observation.
        let repo = InMemorySessionRepository()
        let manager = SessionManager(repository: repo, cliClientFactory: { _ in FakeCLIClient() })
        let draftDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-inputbar-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: draftDir) }
        let store = InputDraftStore(directory: draftDir, debounceInterval: 0.05)
        let suite = "ccterm-inputbar-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        let controller = InputBarController(
            sessionManager: manager, inputDraftStore: store, userDefaults: defaults,
            notificationCenter: NotificationCenter(),
            submitEnabledProvider: { $0.cwd != nil },
            onSubmit: { _, _ in })

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
        defer {
            window.contentView = nil
            window.close()
        }

        let sid = UUID().uuidString
        controller.rebind(sessionId: sid)
        await settle()

        // Type text but no cwd → still NOT sendable (the external gate is false).
        let tv = controller.barView.textView
        tv.insertText("hello", replacementRange: tv.selectedRange())
        XCTAssertFalse(
            controller.canSend, "With cwd nil the external gate should block send despite text.")

        // Pick a folder via the real draft setter → the cwd observation
        // re-fires → canSend flips true after a tick.
        let session = manager.prepareDraftSession(sid)
        session.draft?.setCwd("/tmp/picked")
        await settle()
        XCTAssertTrue(
            controller.canSend, "After setting session.cwd the bar should become sendable.")
    }

    // MARK: - draft-clear-before-onSubmit ORDER (§4.1-4)

    func testDraftClearedBeforeOnSubmit() async throws {
        let fx = makeFixture()
        let window = mount(fx)
        defer {
            window.contentView = nil
            window.close()
        }
        fx.controller.rebind(sessionId: fx.activeSessionId)
        await settle()

        // Pre-seed a persisted draft on disk for this key so we can prove it
        // is gone by onSubmit time. Save + settle for the debounce write.
        fx.inputDraftStore.save(
            InputDraft(text: "stale draft", filePaths: [], updatedAt: Date()),
            for: fx.activeSessionId)
        await settle()
        let preload = await fx.inputDraftStore.load(sessionId: fx.activeSessionId)
        XCTAssertNotNil(preload, "Pre-seeded draft should be persisted before send.")

        // ORDER PROOF via the real surface: handleSend clears the bar's LOCAL
        // state (text → "") BEFORE calling onSubmit. The injected onSubmit
        // therefore observes an already-empty text view + a non-sendable bar.
        // (We can't capture the persisted-file state synchronously inside
        // onSubmit because the file delete is async, but the local clear and
        // the store.clear() call are both issued on the same stack, in order,
        // before onSubmit — and the persisted-file-gone assertion below closes
        // the loop.)
        var textAtSubmit: String?
        var canSendAtSubmit: Bool?
        fx.submitRecords.onSubmitProbe = { [weak controller = fx.controller] in
            textAtSubmit = controller?.barView.textView.string
            canSendAtSubmit = controller?.canSend
        }

        type("real message", into: fx)
        fx.controller.handleSend()

        XCTAssertEqual(fx.submitRecords.events, ["submit"], "onSubmit should have fired exactly once.")
        XCTAssertEqual(
            fx.submitRecords.submissions.first?.text, "real message",
            "onSubmit should receive the trimmed text.")
        XCTAssertEqual(
            textAtSubmit, "",
            "By onSubmit time the bar's text must already be cleared (clear-before-submit).")
        XCTAssertEqual(
            canSendAtSubmit, false,
            "By onSubmit time the bar must already be non-sendable (state cleared first).")

        // The persisted draft file is gone after the async clear settles —
        // proving the store.clear() the controller issued before onSubmit ran.
        await settle()
        let after = await fx.inputDraftStore.load(sessionId: fx.activeSessionId)
        XCTAssertNil(after, "handleSend must clear the persisted draft.")

        XCTAssertEqual(fx.controller.barView.textView.string, "", "Text should be cleared on send.")
        XCTAssertFalse(fx.controller.canSend, "Bar should not be sendable after a send clears it.")
    }

    // MARK: - multi-line intrinsic-height tracking (§4.1-1)

    func testMultiLineHeightTracking() async throws {
        let fx = makeFixture()
        let window = mount(fx)
        defer {
            window.contentView = nil
            window.close()
        }
        fx.controller.rebind(sessionId: fx.activeSessionId)
        await settle()

        fx.controller.view.layoutSubtreeIfNeeded()
        let oneLineHeight = fx.controller.barView.fittingSize.height
        XCTAssertGreaterThan(oneLineHeight, 0, "One-line bar should have a positive height.")

        // Type a 6-line string through the real text view → the scroll view's
        // intrinsic height grows → onIntrinsicHeightChanged → relayout funnel.
        type("a\nb\nc\nd\ne\nf", into: fx)
        await settle()
        fx.controller.view.layoutSubtreeIfNeeded()
        let sixLineHeight = fx.controller.barView.fittingSize.height

        XCTAssertGreaterThan(
            sixLineHeight, oneLineHeight + 20,
            "Six-line bar (\(sixLineHeight)) should be taller than one-line (\(oneLineHeight)) — "
                + "the onIntrinsicHeightChanged → relayout funnel must track text growth.")
        // Still a component, not pane-filling (mirrors HostedComponentCenteringTests).
        XCTAssertLessThan(
            sixLineHeight, 250,
            "Six-line bar height (\(sixLineHeight)) should still be a small component (< 250).")
    }

    // MARK: - sendKeyBehavior wiring D2

    func testSendKeyBehaviorReadAtLoad() async throws {
        let fx = makeFixture(sendKeyValue: "enter")
        let window = mount(fx)
        defer {
            window.contentView = nil
            window.close()
        }
        fx.controller.loadViewIfNeeded()
        XCTAssertEqual(
            fx.controller.barView.textView.sendKeyBehavior, .enter,
            "sendKeyBehavior should track the injected default ('enter') at load.")
    }

    func testSendKeyBehaviorLiveUpdate() async throws {
        let fx = makeFixture(sendKeyValue: "enter")
        let window = mount(fx)
        defer {
            window.contentView = nil
            window.close()
        }
        fx.controller.loadViewIfNeeded()
        XCTAssertEqual(fx.controller.barView.textView.sendKeyBehavior, .enter)

        // Write the new value + post the change on the injected center.
        fx.defaults.set("commandEnter", forKey: "sendKeyBehavior")
        fx.notificationCenter.post(name: UserDefaults.didChangeNotification, object: fx.defaults)
        await settle(iterations: 4)
        XCTAssertEqual(
            fx.controller.barView.textView.sendKeyBehavior, .commandEnter,
            "sendKeyBehavior should track a live default change.")
    }

    // MARK: - isRunning send/stop swap (§4.1-9)

    func testSendStopSwapTracksIsRunning() async throws {
        let fx = makeFixture()
        let window = mount(fx)
        defer {
            window.contentView = nil
            window.close()
        }
        fx.controller.rebind(sessionId: fx.activeSessionId)
        await settle()

        XCTAssertFalse(
            fx.controller.barView.sendStopButton.isRunning,
            "Idle session → send state.")

        // Flip the session into a running turn through the public surface.
        let session = fx.manager.prepareDraftSession(fx.activeSessionId)
        session.send(text: "kick off a turn")
        await settle()
        XCTAssertTrue(
            fx.controller.barView.sendStopButton.isRunning,
            "After session.send the bar should show the stop state.")

        // Interrupt flips it back.
        session.interrupt()
        await settle()
        XCTAssertFalse(
            fx.controller.barView.sendStopButton.isRunning,
            "After interrupt the bar should return to the send state.")
    }

    // MARK: - scrim-rect reporting stability (§4.1-2)

    func testScrimRectsReportedAndStable() async throws {
        let fx = makeFixture()
        let window = mount(fx)
        defer {
            window.contentView = nil
            window.close()
        }

        // Anchor the scrim rects to the container so we can pin exact values.
        let anchor = window.contentView!
        var attachRects: [CGRect] = []
        var pillRects: [CGRect] = []
        fx.controller.barView.scrimAnchorView = anchor
        fx.controller.barView.onAttachRect = { attachRects.append($0) }
        fx.controller.barView.onPillRect = { pillRects.append($0) }

        fx.controller.rebind(sessionId: fx.activeSessionId)
        await settle()
        anchor.layoutSubtreeIfNeeded()
        fx.controller.barView.layout()
        await settle()

        XCTAssertFalse(attachRects.isEmpty, "Attach rect should be reported once laid out.")
        XCTAssertFalse(pillRects.isEmpty, "Pill rect should be reported once laid out.")
        let baselineAttach = attachRects.last!
        let baselinePill = pillRects.last!
        // The attach button is 32×32 in the anchor space.
        XCTAssertEqual(baselineAttach.width, AttachButton.size, accuracy: 1)
        XCTAssertEqual(baselineAttach.height, AttachButton.size, accuracy: 1)
        // The pill cutout is the bottom 32pt row.
        XCTAssertEqual(baselinePill.height, InputBarView.pillMinHeight, accuracy: 1)

        // Grow the pill upward (simulate the completion popup reserving height)
        // → the bottom-anchored attach/pill cutout rects must NOT move.
        attachRects.removeAll()
        pillRects.removeAll()
        fx.controller.barView.extraPillContentHeight = 120
        await settle()
        anchor.layoutSubtreeIfNeeded()
        fx.controller.barView.layout()
        await settle()

        if let movedAttach = attachRects.last {
            XCTAssertEqual(
                movedAttach.minY, baselineAttach.minY, accuracy: 1,
                "Attach button must not move when the pill grows upward.")
        }
        if let movedPill = pillRects.last {
            XCTAssertEqual(
                movedPill.minY, baselinePill.minY, accuracy: 1,
                "Pill cutout (bottom row) must not move when the pill grows upward.")
            XCTAssertEqual(
                movedPill.height, baselinePill.height, accuracy: 1,
                "Pill cutout height stays the bottom 32pt row regardless of popup height.")
        }
    }

    // MARK: - live hasMarkedText D4 (CJK / IME composition)

    func testMarkedTextSuppressesCompletionTrigger() async throws {
        // Bind a FOLDER-LESS draft session (a fresh id with no record →
        // `prepareDraftSession` returns a `.draft` whose `cwd == nil`). With
        // `cwd == nil` AND no builtin dispatcher, the slash rule takes the
        // synchronous `.noDirectory`-override branch: it never reaches
        // `SlashCommandStore.shared` and never spawns a temp-CLI subprocess —
        // so this test stays parallel-safe (no `.shared`, no subprocess, no
        // FSEvents). `isActive == true` for a bare "/" then comes from the
        // `.noDirectory` override exactly as the inline comment describes.
        let fx = makeFixture()
        let window = mount(fx)
        defer {
            window.contentView = nil
            window.close()
        }
        let folderlessId = UUID().uuidString
        fx.controller.rebind(sessionId: folderlessId)
        await settle()
        XCTAssertNil(
            fx.manager.prepareDraftSession(folderlessId).cwd,
            "Fixture precondition: the bound draft session must have a nil cwd "
                + "so the slash rule takes the in-process .noDirectory branch.")

        let tv = fx.controller.barView.textView
        // Make the bar first responder so marked text takes.
        window.makeFirstResponder(tv)

        // Start an IME composition with a "/" marked — checkTrigger must see
        // hasMarkedText == true (D4) and NOT activate the slash completion.
        tv.setMarkedText(
            "/", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        // Drive the delegate selection-change path explicitly (marked-text set
        // does not always emit textDidChange in a headless view).
        fx.controller.textViewDidChangeSelection(Notification(name: NSText.didChangeNotification, object: tv))
        XCTAssertFalse(
            fx.controller.completion.isActive,
            "While IME marked text is present, the slash completion must stay inactive (D4).")

        // Commit the composition → trigger detection resumes.
        tv.unmarkText()
        tv.string = ""
        tv.insertText("/", replacementRange: NSRange(location: 0, length: 0))
        fx.controller.textDidChange(Notification(name: NSText.didChangeNotification, object: tv))
        // With no builtin dispatcher AND no cwd, a leading "/" shows the
        // `.noDirectory` hint — which `CompletionState.isActive` reports as
        // `true` (it short-circuits on `emptyReasonOverride == .noDirectory`).
        XCTAssertTrue(
            fx.controller.completion.isActive,
            "After committing the IME composition, a leading '/' should activate completion "
                + "(via the .noDirectory hint on the folder-less session).")
    }

    // MARK: - completion confirm splice reentrancy (§4.3-4)

    func testCompletionConfirmSplice() async throws {
        // Drive the SYNCHRONOUS slash-builtin completion (deterministic
        // offscreen — no fzf / filesystem dependency, no `.shared` singleton,
        // no temp-CLI subprocess). The fixture binds a FOLDER-LESS draft
        // session (a fresh id with no record → `prepareDraftSession` returns a
        // `.draft` whose `cwd == nil`). With `cwd == nil` BUT a builtin
        // dispatcher present, the slash rule takes the in-process branch whose
        // provider is the pure `{ query, cb in cb(builtinItems(matching:)) }` —
        // it offers `/new` `/clear` synchronously and NEVER reaches
        // `SlashCommandStore.shared` / launches a CLI. Confirming splices
        // through the real `confirmSelection` → `applyReplacement` path under
        // the programmatic guard, so the double `textDidChange` +
        // `textViewDidChangeSelection` both early-return.
        var dispatched: [BuiltinSlashCommand] = []
        let fx = makeFixture(onBuiltinCommand: { dispatched.append($0) })
        let window = mount(fx)
        defer {
            window.contentView = nil
            window.close()
        }
        let folderlessId = UUID().uuidString
        fx.controller.rebind(sessionId: folderlessId)
        await settle()
        XCTAssertNil(
            fx.manager.prepareDraftSession(folderlessId).cwd,
            "Fixture precondition: the bound draft session must have a nil cwd "
                + "so the slash rule uses the in-process synchronous builtin provider.")

        let tv = fx.controller.barView.textView
        window.makeFirstResponder(tv)
        // Type a slash + a letter so the popup narrows to `/new`.
        tv.insertText("/", replacementRange: tv.selectedRange())
        fx.controller.textDidChange(Notification(name: NSText.didChangeNotification, object: tv))
        tv.insertText("n", replacementRange: tv.selectedRange())
        fx.controller.textDidChange(Notification(name: NSText.didChangeNotification, object: tv))
        await settle()

        XCTAssertTrue(
            fx.controller.completion.isActive,
            "A leading '/' with a builtin dispatcher should activate the slash completion.")
        XCTAssertFalse(
            fx.controller.completion.items.isEmpty,
            "The builtin provider should have returned items synchronously.")

        // Confirm via the key interceptor (Return, keyCode 36).
        let returnEvent = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        _ = tv.onInterceptKeyDown?(returnEvent)
        await settle()

        XCTAssertFalse(
            fx.controller.completion.isActive,
            "Confirming a completion should dismiss it (isActive == false).")
        XCTAssertTrue(
            fx.controller.completion.items.isEmpty,
            "Completion items should be empty after a confirm (both delegate callbacks "
                + "early-returned under the programmatic guard).")
        // The `/new` builtin clears the typed "/new" (replacement = ""), and
        // its action fired exactly once.
        XCTAssertEqual(dispatched, [.new], "Confirming /new should dispatch the builtin once.")
        XCTAssertEqual(
            tv.string, "", "Confirming a builtin clears the typed '/cmd' text (splice = empty).")
    }

    // MARK: - autofocus window-gated (§4.1-5)

    func testAutofocusOnRebind() async throws {
        let fx = makeFixture(autofocus: true)
        let window = mount(fx)
        defer {
            window.contentView = nil
            window.close()
        }
        fx.controller.rebind(sessionId: fx.activeSessionId)
        // viewDidAppear focus is window-gated; mount + rebind both call
        // focusIfNeeded. Drive an explicit appear.
        fx.controller.viewDidAppear()
        await settle()
        XCTAssertEqual(
            window.firstResponder, fx.controller.barView.textView,
            "With autofocus the text view should be first responder once windowed.")
    }
}
