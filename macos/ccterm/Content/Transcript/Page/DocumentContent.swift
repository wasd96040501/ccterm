import Foundation

/// What opens beside the transcript for something on the page — the domain
/// values, whole. How each is drawn is its document body's
/// (`DocumentViewController.makeBody(for:)`), which derives everything it shows from
/// these; the page decides only *which* document a click means.
nonisolated enum DocumentContent: Sendable, Equatable {
    /// A Bash call: the command document.
    case command(ToolCall)
    /// A `!` command the reader ran: the command document, titled *You ran*.
    case shellCommand(LocalCommand)
    /// Edits to one file — one call, or consecutive ones combined.
    case change([ToolCall])
    /// A file written from nothing.
    case newFile(ToolCall)
    case read(ToolCall)
    /// Grep, Glob, ToolSearch: what matched, where.
    case search(ToolCall)
    /// WebFetch or WebSearch.
    case web(ToolCall)
    /// A subagent: its answer, and the way to its own transcript.
    case agent(ToolCall)
    /// A subagent's report, sent into the conversation: its words, whole.
    case agentMessage(AgentMessage)
    /// The task list as it stood after a tasks call.
    case taskList([TaskListItem])
    /// What a background agent, workflow or monitor reported. A command's
    /// news opens the command's own document instead.
    case news(TaskNews)
    /// A slash command's output, too long for the line under its capsule.
    case commandOutput(LocalCommand)
    /// The summary a compaction left for the model to continue from.
    case compactionSummary(String)
    /// Any other tool: its input and its result, as they were recorded.
    case other(ToolCall)
}
