import AgentSDK
import DisplayModels
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
    /// The advisor's answer, for the advisor's call: a server tool, whose
    /// result is in the reply that made the call.
    var advisor: AdvisorOutcome? = nil

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

    /// The subagent an Agent call ran, once its result names it: the id of
    /// its conversation, `subagents/agent-<id>.jsonl` beside the session's.
    var agentID: String? {
        switch result?.toolOutcome(Tools.Agent.self) {
        case .success(.completed(let done)) where !done.agentID.isEmpty: done.agentID
        case .success(.launched(let agentID, _)) where !agentID.isEmpty: agentID
        default: nil
        }
    }
}

nonisolated extension ToolCall {
    /// Whether a click opens something beside. Everything does but an advisor
    /// whose advice can't be read — encrypted, declined, an error — which says
    /// all there is on its line.
    var opensBeside: Bool {
        kind == .advisor ? advisor?.advice != nil : true
    }

    /// The message of a `SendMessage`.
    var sentMessage: SentMessage? {
        kind == .message ? SentMessage(use.input) : nil
    }

    /// The skill a `Skill` call ran.
    var skillName: String? {
        kind == .skill ? use.input["skill"]?.stringValue : nil
    }

    /// An MCP tool's server and tool (`mcp__computer-use__screenshot`);
    /// any other tool is its own server.
    var toolName: (server: String, tool: String) {
        let parts = use.name.components(separatedBy: "__")
        if parts.count >= 3, parts[0] == "mcp" { return (parts[1], parts[2...].joined(separator: "__")) }
        return (use.name, use.name)
    }
}
