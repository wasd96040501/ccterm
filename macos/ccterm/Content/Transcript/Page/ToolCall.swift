import AgentSDK
import Foundation

/// One tool call as the page knows it: what was asked, what came back, and
/// how it went.
///
/// The SDK's own values are kept whole — `use` and `result` — rather than
/// copied into fields of this type: a document beside the transcript reads
/// the tool's typed input and output from them (`use.input(as:)`,
/// `result?.toolOutcome(_:)`), and the page adds only what the SDK can't
/// say on its own — the kind, the state, the times.
nonisolated struct ToolCall: Sendable, Equatable, Identifiable {
    let use: ToolUseBlock
    /// The message carrying the call's result; `nil` until it has one.
    var result: UserMessage?
    let kind: ToolKind
    var state: ToolCallState
    /// When the model asked for the call — its assistant message's time.
    let startedAt: Date?
    /// When the result was recorded.
    var finishedAt: Date?

    var id: String { use.id }

    /// Wall time from request to result, when both are known.
    var duration: TimeInterval? {
        guard let startedAt, let finishedAt else { return nil }
        return max(0, finishedAt.timeIntervalSince(startedAt))
    }

    /// Asked to run in the background — a command or an agent whose news
    /// arrives later as a `TaskNews`.
    var ranInBackground: Bool {
        use.input["run_in_background"]?.boolValue ?? false
    }

    /// The file a change, creation or read is about.
    var filePath: String? {
        use.input["file_path"]?.stringValue ?? use.input["notebook_path"]?.stringValue
    }
}
