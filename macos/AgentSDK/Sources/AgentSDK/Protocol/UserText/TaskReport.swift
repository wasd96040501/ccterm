import Foundation

/// What the CLI tells the model about a background task — a command, an
/// agent, a workflow, a monitor — as a user message of its own (a
/// `<task-notification>` element, read as
/// ``UserMessage/Kind/taskNotification(_:)``). Every field the CLI writes;
/// which are present depends on the task.
///
/// A live ``Session`` also tells its host that a task ended, separately and
/// in less detail: ``SystemMessage/taskNotification(_:)``.
public struct TaskReport: Sendable, Equatable {
    /// How the task ended, or `nil` for a notice that is not an ending (a
    /// monitor's event, a goal check-in).
    public enum Status: Sendable, Equatable {
        case completed
        case failed
        case stopped
        case killed
        case unknown(String)
    }

    /// What an agent or workflow task used.
    public struct Usage: Sendable, Equatable {
        public var totalTokens: Int?
        public var totalToolUseCount: Int?
        public var totalDurationMS: Int?
        /// A workflow's agents, and how many of them finished, failed, were
        /// skipped, or finished with nothing to report.
        public var agentCount: Int?
        public var agentsDone: Int?
        public var agentsFailed: Int?
        public var agentsSkipped: Int?
        public var agentsWithEmptyResult: Int?

        public init(
            totalTokens: Int? = nil, totalToolUseCount: Int? = nil, totalDurationMS: Int? = nil,
            agentCount: Int? = nil, agentsDone: Int? = nil, agentsFailed: Int? = nil, agentsSkipped: Int? = nil,
            agentsWithEmptyResult: Int? = nil
        ) {
            self.totalTokens = totalTokens
            self.totalToolUseCount = totalToolUseCount
            self.totalDurationMS = totalDurationMS
            self.agentCount = agentCount
            self.agentsDone = agentsDone
            self.agentsFailed = agentsFailed
            self.agentsSkipped = agentsSkipped
            self.agentsWithEmptyResult = agentsWithEmptyResult
        }
    }

    /// One line on what happened: `Agent "Review" finished`,
    /// `Background command "Build" completed (exit code 0)`.
    public var summary: String
    public var status: Status?
    /// The tasks this is about, as the tool that started each named it —
    /// one, or several stopped together.
    public var taskIDs: [String]
    /// Set for tasks that are not local: `remote_agent`.
    public var taskType: String?
    /// The tool call that started the task.
    public var toolUseID: String?
    /// Where the task's output is written.
    public var outputFile: String?
    /// An agent's or workflow's final answer.
    public var result: String?
    /// What a monitor saw.
    public var event: String?
    /// A remark on the notification itself, such as that it may repeat.
    public var note: String?
    public var usage: Usage?
    /// The worktree an agent worked in.
    public var worktreePath: String?
    public var worktreeBranch: String?
    /// Where a workflow's per-agent results are.
    public var diagnostics: String?
    /// A workflow's failed steps, one per line.
    public var failures: String?
    /// How to resume a workflow that stopped.
    public var recovery: String?

    public init(
        summary: String, status: Status? = nil, taskIDs: [String] = [], taskType: String? = nil,
        toolUseID: String? = nil, outputFile: String? = nil, result: String? = nil, event: String? = nil,
        note: String? = nil, usage: Usage? = nil, worktreePath: String? = nil, worktreeBranch: String? = nil,
        diagnostics: String? = nil, failures: String? = nil, recovery: String? = nil
    ) {
        self.summary = summary
        self.status = status
        self.taskIDs = taskIDs
        self.taskType = taskType
        self.toolUseID = toolUseID
        self.outputFile = outputFile
        self.result = result
        self.event = event
        self.note = note
        self.usage = usage
        self.worktreePath = worktreePath
        self.worktreeBranch = worktreeBranch
        self.diagnostics = diagnostics
        self.failures = failures
        self.recovery = recovery
    }
}

// MARK: - Reading

extension TaskReport {
    /// Reads a `<task-notification>` element; `nil` if it has no summary.
    init?(_ element: TaggedElement) {
        guard element.name == "task-notification" else { return nil }
        let fields = element.body.topLevelElements
        func text(_ name: String, in fields: [TaggedElement]) -> String? {
            fields.first { $0.name == name.lowercased() }.map { $0.text.unescapingEntities }
        }
        guard let summary = text("summary", in: fields) else { return nil }
        self.init(summary: summary)
        status = text("status", in: fields).map(Status.init)
        taskIDs = fields.filter { $0.name == "task-id" }.map { $0.text.unescapingEntities }
        taskType = text("task-type", in: fields)
        toolUseID = text("tool-use-id", in: fields)
        outputFile = text("output-file", in: fields)
        result = text("result", in: fields)
        event = text("event", in: fields)
        note = text("note", in: fields)
        diagnostics = text("diagnostics", in: fields)
        failures = text("failures", in: fields)
        recovery = text("recovery", in: fields)
        if let usage = fields.first(where: { $0.name == "usage" })?.body.topLevelElements {
            func count(_ name: String) -> Int? { text(name, in: usage).flatMap(Int.init) }
            self.usage = Usage(
                totalTokens: count("subagent_tokens"), totalToolUseCount: count("tool_uses"),
                totalDurationMS: count("duration_ms"), agentCount: count("agent_count"),
                agentsDone: count("agents_done"), agentsFailed: count("agents_error"),
                agentsSkipped: count("agents_skipped"), agentsWithEmptyResult: count("agents_empty_result"))
        }
        if let worktree = fields.first(where: { $0.name == "worktree" })?.body.topLevelElements {
            worktreePath = text("worktreePath", in: worktree)
            worktreeBranch = text("worktreeBranch", in: worktree)
        }
    }
}

extension TaskReport.Status {
    init(_ raw: String) {
        switch raw {
        case "completed": self = .completed
        case "failed": self = .failed
        case "stopped": self = .stopped
        case "killed": self = .killed
        default: self = .unknown(raw)
        }
    }
}

extension String {
    /// The CLI escapes `&`, `<` and `>` in a notification's values.
    fileprivate var unescapingEntities: String {
        guard contains("&") else { return self }
        return replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
