import AgentSDK
import XCTest

@testable import ccterm

/// Pins the sidebar unread-dot (`hasUnread`) trigger contract.
///
/// The unread dot must mirror the notification **banner** triggers, which
/// are exactly two (see `NotificationService` / `finishTurn` /
/// `enqueuePermission`):
///
///   1. A user-initiated turn finished — the `.responding → .idle` edge
///      that fires `onTurnEnded`.
///   2. A permission card appeared — `onPermissionPrompt`.
///
/// Regression target: `appendToTimeline` used to set `hasUnread = true` on
/// **every** live visible message append. That lit the dot mid-turn — the
/// moment the agent emitted its first tool_use (a groupable assistant
/// message), well before the turn ended and with no permission card. On an
/// unfocused session the dot appeared with neither a turn-end nor a
/// permission signal, which is the bug these tests lock out.
@MainActor
final class SessionRuntimeUnreadTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    private func makeRuntime() -> (SessionRuntime, FakeCLIClient) {
        let fake = FakeCLIClient()
        let runtime = SessionRuntime(
            sessionId: UUID().uuidString,
            repository: InMemorySessionRepository(),
            cliClientFactory: { _ in fake }
        )
        runtime.config.cwd = "/tmp/unread-tests"
        return (runtime, fake)
    }

    /// Drive bootstrap to attached + `.idle` (mirrors
    /// `SessionRuntimeIsRunningTests`).
    private func bootstrap(_ runtime: SessionRuntime, _ fake: FakeCLIClient) async {
        runtime.activate()
        for _ in 0..<16 {
            await Task.yield()
            if !fake.initializeCalls.isEmpty { break }
        }
        XCTAssertFalse(fake.initializeCalls.isEmpty, "bootstrap should call initialize")
        fake.completeInitialize(with: nil)
        for _ in 0..<16 {
            await Task.yield()
            if runtime.status == .idle { break }
        }
        XCTAssertEqual(runtime.status, .idle)
    }

    /// Send a user message and flush the queue via `system.init` so the
    /// runtime reaches `.responding` — the real state a live turn is in
    /// while the agent streams its reply.
    private func startTurn(_ runtime: SessionRuntime) {
        runtime.send(text: "hi")
        runtime.receive(Message2Fixtures.systemInit())
        XCTAssertEqual(runtime.status, .responding, "send + system.init should enter .responding")
    }

    // MARK: - The bug: mid-turn activity must NOT mark unread

    /// A fresh, unfocused runtime receives a single assistant tool_use —
    /// the canonical mid-turn signal. No `.result`, no permission card.
    /// The unread dot must stay dark.
    ///
    /// Pre-fix this fails: `appendToTimeline` flipped `hasUnread = true`
    /// the instant the tool_use landed.
    func testMidTurnToolUseDoesNotMarkUnread() {
        let (runtime, _) = makeRuntime()
        XCTAssertFalse(runtime.isFocused, "a fresh runtime is unfocused")
        XCTAssertFalse(runtime.hasUnread)

        runtime.receive(
            Message2Fixtures.assistantRead(toolUseId: "t1", filePath: "/tmp/x.txt"))

        XCTAssertFalse(
            runtime.hasUnread,
            "a mid-turn tool_use must NOT mark unread — no turn-end, no permission card")
    }

    // MARK: - Turn end DOES mark unread (when unfocused)

    /// Full unfocused turn: tool_use → tool_result → text → `.result`.
    /// `hasUnread` stays dark through every mid-turn append and only lights
    /// at the `.result` turn-end edge.
    func testTurnEndMarksUnreadWhenUnfocused() async {
        let (runtime, fake) = makeRuntime()
        await bootstrap(runtime, fake)
        XCTAssertFalse(runtime.isFocused)

        startTurn(runtime)

        runtime.receive(
            Message2Fixtures.assistantRead(toolUseId: "t1", filePath: "/tmp/x.txt"))
        XCTAssertFalse(runtime.hasUnread, "tool_use mid-turn must not mark unread")

        runtime.receive(Message2Fixtures.userToolResult(toolUseId: "t1"))
        XCTAssertFalse(runtime.hasUnread, "tool_result mid-turn must not mark unread")

        runtime.receive(Message2Fixtures.assistantText("done", messageId: "m-final"))
        XCTAssertFalse(runtime.hasUnread, "intermediate assistant text must not mark unread")

        runtime.receive(Message2Fixtures.result())
        XCTAssertTrue(
            runtime.hasUnread,
            "turn end (.responding → .idle) must mark unread on an unfocused session")
    }

    // MARK: - CLI-spontaneous turn finish also marks unread

    /// A turn the CLI starts on its own (e.g. a background-bash completion
    /// surfacing its result) never enters `.responding` — it just flips
    /// `isRunning` on the stray `.assistant` and closes on `.result`. The
    /// unread dot must still light: it corresponds to the *turn-finish* event
    /// (every live `.result`), not only the user-initiated `.responding →
    /// .idle` edge.
    func testCLISpontaneousTurnFinishMarksUnread() async {
        let (runtime, fake) = makeRuntime()
        await bootstrap(runtime, fake)
        XCTAssertFalse(runtime.isFocused)
        XCTAssertEqual(runtime.status, .idle)

        // No user send → no `.responding`. CLI spontaneously produces a turn.
        runtime.receive(Message2Fixtures.assistantText("bg job done", messageId: "m-bg"))
        XCTAssertFalse(runtime.hasUnread, "mid-turn assistant must not mark unread")
        XCTAssertNotEqual(runtime.status, .responding, "spontaneous turn never enters .responding")

        runtime.receive(Message2Fixtures.result())
        XCTAssertTrue(
            runtime.hasUnread,
            "a CLI-spontaneous turn finish (.result without .responding) must mark unread")
    }

    // MARK: - Focused session: turn end does NOT mark unread

    /// The same full turn on a focused session never lights the dot — the
    /// user is already looking at it.
    func testTurnEndDoesNotMarkUnreadWhenFocused() async {
        let (runtime, fake) = makeRuntime()
        await bootstrap(runtime, fake)
        runtime.setFocused(true)

        startTurn(runtime)
        runtime.receive(
            Message2Fixtures.assistantRead(toolUseId: "t1", filePath: "/tmp/x.txt"))
        runtime.receive(Message2Fixtures.userToolResult(toolUseId: "t1"))
        runtime.receive(Message2Fixtures.assistantText("done", messageId: "m-final"))
        runtime.receive(Message2Fixtures.result())

        XCTAssertFalse(
            runtime.hasUnread,
            "a focused session must never light the unread dot")
    }
}
