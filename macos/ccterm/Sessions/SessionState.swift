import AgentSDK
import Foundation

/// A session as it stands: its conversation, and — while a CLI runs it — the
/// response streaming in, the requests waiting for the reader, and whether
/// a turn is running. A value; `SessionStore` hands out one per change.
///
/// Read from disk, it is only `transcript` (`isLive` false). Kept live, it
/// is folded from the session's events by `apply(_:)`, a pure function —
/// everything `LiveSession` knows about the CLI goes through it.
nonisolated struct SessionState: Sendable {
    /// What the sidebar shows of a live session. A session no CLI runs has
    /// none (`activity` is `nil`).
    enum Activity: Sendable, Equatable {
        /// Running, no turn.
        case idle
        /// A turn is running.
        case responding
        /// A request waits for the reader; wins over `responding`.
        case needsInput
        /// The CLI exited without being asked to; its message.
        case failed(message: String)
    }

    /// The conversation: what was on disk, then what the live session added.
    var transcript: Transcript
    /// The response streaming in, only the blocks `transcript` doesn't have
    /// yet; `nil` between responses.
    var partial: AssistantMessage?
    /// Permission requests waiting for the reader, oldest first.
    var requests: [PermissionRequest] = []
    /// Whether a CLI runs this session.
    var isLive = false
    /// Whether a turn is running: from a prompt sent until its result.
    var isResponding = false
    /// How the CLI ended, when it ended without being asked to.
    var failure: Termination?

    init(transcript: Transcript) {
        self.transcript = transcript
    }

    /// `nil` while no CLI runs it; otherwise the most urgent thing true of it.
    var activity: Activity? {
        guard isLive || failure != nil else { return nil }
        if let failure { return .failed(message: failure.stderr) }
        if !requests.isEmpty { return .needsInput }
        return isResponding ? .responding : .idle
    }

    /// Folds one event of the live session: messages into `transcript`
    /// (`Transcript.append`) and `partial` (stream events), requests in and
    /// out, a turn's start (`commandLifecycle` started) and end (`result`),
    /// the process's exit.
    mutating func apply(_ event: SessionEvent) {
        // TODO(live): the fold, tested event by event in SessionStateTests.
    }
}
