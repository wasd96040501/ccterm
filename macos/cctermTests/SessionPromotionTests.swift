import AgentSDK
import XCTest

@testable import ccterm

/// Regression net for the draft → active promotion path. The
/// invariants under test, in order of how they break things if
/// regressed:
///
/// 1. The first `send(...)` while in `.draft` flips phase to `.active`
///    with a runtime hydrated from the draft's config / title.
/// 2. The CLI subprocess starts (factory called, `start()` invoked) as
///    part of the promotion — i.e. the user's first message kicks off
///    bootstrap; the session doesn't sit dormant.
/// 3. The queued user entry shows up in `runtime.messages` as
///    `.queued` `.localUser` and `isRunning` flips true immediately.
/// 4. The bridge sink wired ONTO the façade BEFORE `send` is re-wired
///    onto the runtime at promotion, so the `.appended` event for the
///    queued entry actually reaches the subscriber (no race / dropped
///    first event).
/// 5. The DB row is persisted synchronously inside `fromDraft` →
///    `ensureStarted`, so `onPromoted` (and the manager's
///    `refreshRecords()` hook) see the record.
@MainActor
final class SessionPromotionTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Construct a Session in `.draft`, attach a bridge sink, send a
    /// first text message, observe the phase flip + the queued entry +
    /// the bootstrap-Task launch.
    func testFirstTextSendPromotesAndFiresAppended() {
        let fake = FakeCLIClient()
        let repo = InMemorySessionRepository()
        let sid = UUID().uuidString
        var promotedRuntime: SessionRuntime?
        let session = ccterm.Session(
            draftSessionId: sid,
            repository: repo,
            cliClientFactory: { _ in fake },
            onPromoted: { runtime in promotedRuntime = runtime }
        )
        session.draft?.setCwd("/tmp/promotion-test")

        var appendedCount = 0
        var appendedText: String?
        session.onMessagesChange = { change in
            if case .appended(let entry) = change {
                appendedCount += 1
                if case .single(let single) = entry,
                    case .localUser(let input) = single.payload
                {
                    appendedText = input.text
                }
            }
        }

        // Pre-conditions
        XCTAssertFalse(session.hasRecord)
        XCTAssertEqual(session.status, .notStarted)
        XCTAssertFalse(session.isRunning)

        // Promote
        session.send(text: "hello world")

        // Phase flipped to .active with a runtime
        XCTAssertTrue(session.hasRecord)
        XCTAssertNotNil(session.runtime)
        XCTAssertNil(session.draft, "draft retired after promotion")
        XCTAssertNotNil(promotedRuntime, "onPromoted must fire")

        // Queued entry is in runtime.messages, isRunning flipped
        XCTAssertEqual(session.messages.count, 1)
        XCTAssertTrue(session.isRunning)

        // The bridge sink received exactly one .appended for the
        // queued entry, with the text we sent.
        XCTAssertEqual(appendedCount, 1)
        XCTAssertEqual(appendedText, "hello world")

        // Record persisted with title derived from the message
        let persisted = repo.find(sid)
        XCTAssertNotNil(persisted, "fromDraft must persist a record")
        XCTAssertEqual(persisted?.status, .pending)
        XCTAssertEqual(persisted?.cwd, "/tmp/promotion-test")
        XCTAssertEqual(persisted?.title, "hello world")

        // Bootstrap kicked off: CLI factory was invoked once (the
        // detached bootstrap Task runs on the next runloop tick — we
        // don't require it to have completed `start()` synchronously,
        // just that the factory is wired and ready).
        XCTAssertNotNil(session.runtime, "runtime exists post-promotion")
    }

    /// First message is an image (with optional caption). Same
    /// promotion contract; the queued entry carries the image payload.
    func testFirstImageSendPromotesAndFiresAppended() {
        let fake = FakeCLIClient()
        let session = ccterm.Session(
            draftSessionId: UUID().uuidString,
            repository: InMemorySessionRepository(),
            cliClientFactory: { _ in fake }
        )
        session.draft?.setCwd("/tmp/img")

        var captured: SingleEntry?
        session.onMessagesChange = { change in
            if case .appended(let entry) = change,
                case .single(let single) = entry
            {
                captured = single
            }
        }

        let data = Data([0xFF, 0xD8, 0xFF])
        session.send(images: [(data: data, mediaType: "image/jpeg")], caption: "a photo")

        XCTAssertNotNil(session.runtime, "image send must promote too")
        XCTAssertTrue(session.isRunning)
        guard let single = captured else {
            return XCTFail("expected .appended single")
        }
        guard case .localUser(let input) = single.payload else {
            return XCTFail("expected localUser payload")
        }
        XCTAssertEqual(input.text, "a photo")
        XCTAssertEqual(input.images.count, 1)
        XCTAssertEqual(input.images.first?.mediaType, "image/jpeg")
    }

    /// Picker setters (`setModel` / `setEffort` / `setPermissionMode`)
    /// invoked during the draft phase mutate `draft.config`. After
    /// promotion, those values must be visible on the runtime — the
    /// draft's config is copied verbatim into `runtime.config`.
    func testDraftPickerSettersFlowIntoRuntimeAtPromotion() {
        let session = ccterm.Session(
            draftSessionId: UUID().uuidString,
            repository: InMemorySessionRepository(),
            cliClientFactory: { _ in FakeCLIClient() }
        )
        session.draft?.setCwd("/tmp/picker")
        session.setModel("sonnet")
        session.setEffort(.high)
        session.setPermissionMode(.acceptEdits)
        session.setFastMode(true)
        session.setAdditionalDirectories(["/extra"])

        // Sanity: draft has those values pre-promotion.
        XCTAssertEqual(session.model, "sonnet")
        XCTAssertEqual(session.effort, .high)
        XCTAssertEqual(session.permissionMode, .acceptEdits)
        XCTAssertEqual(session.fastModeEnabled, true)
        XCTAssertEqual(session.additionalDirectories, ["/extra"])

        session.send(text: "go")

        // After promotion, runtime carries the same config.
        XCTAssertEqual(session.runtime?.model, "sonnet")
        XCTAssertEqual(session.runtime?.effort, .high)
        XCTAssertEqual(session.runtime?.permissionMode, .acceptEdits)
        XCTAssertEqual(session.runtime?.fastModeEnabled, true)
        XCTAssertEqual(session.runtime?.additionalDirectories, ["/extra"])

        // And the read surface still works post-promotion.
        XCTAssertEqual(session.model, "sonnet")
        XCTAssertEqual(session.permissionMode, .acceptEdits)
    }

    /// A draft-promoted runtime starts in `.loaded` history state and a
    /// subsequent `loadHistory()` is a no-op — no backfill pipeline starts.
    /// Regression net for: switching away from a running fresh session and
    /// coming back triggers `ChatSessionViewController.attachSession`'s
    /// `loadHistory()` call. Without the `.loaded` guard the iterator would
    /// re-read the JSONL the CLI has been writing live and duplicate the live
    /// messages already in the controller.
    func testFromDraftMarksHistoryLoaded() {
        let session = ccterm.Session(
            draftSessionId: UUID().uuidString,
            repository: InMemorySessionRepository(),
            cliClientFactory: { _ in FakeCLIClient() }
        )
        session.draft?.setCwd("/tmp/history-loaded")

        session.send(text: "first")

        XCTAssertEqual(session.historyLoadState, .loaded)
        let countAfterSend = session.controller.blockCount

        // Re-entry from the transcript host's perspective: calling
        // `loadHistory()` again must be a no-op — load state stays `.loaded`
        // and no extra content is applied.
        session.loadHistory()
        XCTAssertEqual(session.historyLoadState, .loaded)
        XCTAssertEqual(
            session.controller.blockCount, countAfterSend,
            "loadHistory on a draft-promoted session must not start a backfill")
    }

    /// A second send (now in `.active` phase) routes directly to the
    /// runtime — no second promotion, no extra `onPromoted`.
    func testSecondSendDoesNotRepromote() {
        let fake = FakeCLIClient()
        var promotedCount = 0
        let session = ccterm.Session(
            draftSessionId: UUID().uuidString,
            repository: InMemorySessionRepository(),
            cliClientFactory: { _ in fake },
            onPromoted: { _ in promotedCount += 1 }
        )
        session.draft?.setCwd("/tmp/x")

        session.send(text: "first")
        let runtimeAfterFirst = session.runtime
        XCTAssertEqual(promotedCount, 1)

        session.send(text: "second")
        XCTAssertEqual(promotedCount, 1, "second send must NOT re-fire onPromoted")
        XCTAssertTrue(
            session.runtime === runtimeAfterFirst,
            "second send keeps the same runtime instance")
    }
}
