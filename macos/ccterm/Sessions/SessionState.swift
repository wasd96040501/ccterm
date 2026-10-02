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
    /// yet; `nil` between responses. The fold that appends a finished block's
    /// message drops that block from here, so no state holds a block twice.
    /// Stream events of a subagent (`parentToolUseID`) never fold in here.
    var partial: AssistantMessage?
    /// Permission requests waiting for the reader, oldest first.
    var requests: [PermissionRequest] = []
    /// Whether a CLI runs this session.
    var isLive = false
    /// Whether a turn is running: from a prompt sent until its result.
    var isResponding = false
    /// How the CLI ended, when it ended without being asked to.
    var failure: Termination?
    /// Whether the response in `partial` has stopped streaming (its
    /// `messageStop` came), so that dropping its last finished block ends it.
    private var partialHasStopped = false

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
        switch event {
        case .message(let message):
            apply(message)
        case .permissionRequest(let request):
            requests.append(request)
        case .permissionRequestCancelled(let id):
            requests.removeAll { $0.id == id }
        case .exited(let termination):
            isLive = false
            isResponding = false
            requests = []
            partial = nil
            // A clean exit nobody asked for is the reader's `/exit`: the
            // session is at rest, not failed.
            if termination.exitCode != 0 { failure = termination }
        }
    }

    private mutating func apply(_ message: Message) {
        switch message {
        case .streamEvent(let event):
            apply(event)
        case .assistant(let assistant):
            if assistant.parentToolUseID == nil, var streaming = partial, streaming.messageID == assistant.messageID {
                streaming.content.removeFirst(min(assistant.content.count, streaming.content.count))
                partial = streaming.content.isEmpty && partialHasStopped ? nil : streaming
            }
            transcript.append(message)
        case .user, .system:
            transcript.append(message)
        case .result:
            isResponding = false
            partial = nil
        case .commandLifecycle(let lifecycle):
            if lifecycle.state == .started { isResponding = true }
        default:
            break
        }
    }

    private mutating func apply(_ event: StreamEvent) {
        guard event.parentToolUseID == nil else { return }
        switch event.event {
        case .messageStart:
            partial = AssistantMessage(streamStart: event)
            partialHasStopped = false
        case .messageStop:
            partialHasStopped = true
            if partial?.content.isEmpty == true { partial = nil }
        default:
            partial?.apply(event)
        }
    }
}
