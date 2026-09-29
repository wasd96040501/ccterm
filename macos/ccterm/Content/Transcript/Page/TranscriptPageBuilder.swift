import AgentSDK
import Foundation

/// Reads a transcript's messages into the page's entries — the one place the
/// page's boundaries are decided (design/transcript/01-run.md "Where a run
/// begins and ends", 04-background.md, 05-local.md):
///
/// - Consecutive tool calls with nothing visible between them are one run;
///   thinking, results and text the CLI added for the model are invisible.
///   A question or a plan breaks out of the run it would have been in.
/// - Consecutive task news is one row.
/// - `/compact` folds into its compaction's divider; `/exit` becomes a
///   *Resumed* divider when the transcript goes on; a pause of more than an
///   hour gets a divider of its own.
///
/// Two passes: the first indexes what answers a call — its result, a
/// background task's news, a subagent's description — so the second can
/// settle every call as it meets it.
nonisolated struct TranscriptPageBuilder {
    private let messages: [Message]
    private let writer: WorkLineWriter

    // The first pass's indexes.
    private var results: [String: UserMessage] = [:]
    private var news: [String: (report: TaskReport, at: Date?)] = [:]
    private var agentNames: [String: String] = [:]
    private var calls: [String: ToolUseBlock] = [:]
    private var callStarts: [String: Date] = [:]
    /// Calls in the transcript's last assistant message: a missing result
    /// there means still running, anywhere else it means cut off.
    private var tailCalls: Set<String> = []

    // The second pass's state.
    private var entries: [TranscriptEntry] = []
    private var runCalls: [ToolCall] = []
    private var newsRun: [TaskNews] = []
    private var lastVisible: Date?
    private var exited = false
    private var foldingCompact = false

    /// `workingDirectory` is the session's: paths under it read relative to it.
    init(messages: [Message], workingDirectory: String?) {
        self.messages = messages
        writer = WorkLineWriter(workingDirectory: workingDirectory)
    }

    mutating func build() -> [TranscriptEntry] {
        index()
        for (index, message) in messages.enumerated() {
            read(message, at: index)
        }
        flush()
        return entries
    }

    // MARK: - First pass

    private mutating func index() {
        var lastAssistantCalls: [String] = []
        for message in messages {
            switch message {
            case .assistant(let assistant):
                let ids = assistant.content.compactMap { block -> String? in
                    guard case .toolUse(let call) = block else { return nil }
                    calls[call.id] = call
                    callStarts[call.id] = assistant.timestamp
                    return call.id
                }
                if !ids.isEmpty { lastAssistantCalls = ids }
                if assistant.content.contains(where: { if case .text(let t) = $0 { !t.isEmpty } else { false } }) {
                    lastAssistantCalls = ids
                }
            case .user(let user):
                if let result = user.toolResult {
                    results[result.toolUseID] = user
                    if let call = calls[result.toolUseID], Tools.Agent.matches(call.name),
                        let input = call.input(as: Tools.Agent.self)
                    {
                        switch user.toolOutcome(Tools.Agent.self) {
                        case .success(.completed(let done)): agentNames[done.agentID] = input.description
                        case .success(.launched(let agentID, _)): agentNames[agentID] = input.description
                        default: break
                        }
                    }
                }
                if case .taskNotification(let report) = user.kind, let origin = report.toolUseID {
                    news[origin] = (report, user.timestamp)
                }
            default:
                break
            }
        }
        tailCalls = Set(lastAssistantCalls)
    }

    // MARK: - Second pass

    private mutating func read(_ message: Message, at index: Int) {
        switch message {
        case .assistant(let assistant):
            for (part, block) in assistant.content.enumerated() {
                let id = "\(index).\(part)"
                switch block {
                case .text(let text) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                    appendEntry(.reply(id: id, markdown: text), at: assistant.timestamp)
                case .toolUse(let use):
                    readCall(use, at: assistant.timestamp)
                default:
                    break
                }
            }
        case .user(let user):
            readUser(user, at: index)
        case .system(.compactBoundary(let boundary)):
            foldingCompact = false
            appendEntry(
                .divider(
                    SessionDivider(
                        id: "\(index)",
                        kind: .compacted(
                            automatically: boundary.trigger == "auto",
                            preTokens: boundary.preTokens > 0 ? boundary.preTokens : nil,
                            postTokens: boundary.postTokens))), at: nil)
        default:
            break
        }
    }

    private mutating func readUser(_ user: UserMessage, at index: Int) {
        let id = "\(index)"
        switch user.kind {
        case .prompt:
            let text = user.content.compactMap(\.text).joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { appendEntry(.prompt(id: id, text: text), at: user.timestamp) }
        case .slashCommand(let name, let arguments):
            switch name {
            case "/compact":
                foldingCompact = true
            case "/exit":
                flush()
                exited = true
            default:
                appendEntry(
                    .command(
                        LocalCommand(
                            id: id, command: .slash(name: name, arguments: arguments), output: "", errorOutput: "")),
                    at: user.timestamp)
            }
        case .shellCommand(let command):
            appendEntry(
                .command(LocalCommand(id: id, command: .shell(command), output: "", errorOutput: "")),
                at: user.timestamp)
        case .commandOutput(let standardOutput, let standardError):
            attachOutput(standardOutput, standardError)
        case .taskNotification(let report):
            readNews(report, id: id, at: user.timestamp)
        case .message(let sender, let text):
            appendEntry(.voice(Voice(id: id, sender: sender, name: name(of: sender), text: text)), at: user.timestamp)
        case .interruption(let duringToolUse):
            // During a call it is that call's state, read from its result.
            if !duringToolUse { appendEntry(.interruption(id: id), at: user.timestamp) }
        case .compactionSummary:
            attachSummary(user.content.compactMap(\.text).joined(separator: "\n\n"))
        case .toolResult, .synthetic:
            break
        }
    }

    private mutating func readCall(_ use: ToolUseBlock, at date: Date?) {
        let call = settle(use, startedAt: date)
        if Tools.AskUserQuestion.matches(use.name) {
            let input = use.input(as: Tools.AskUserQuestion.self)
            var answers: [String: String] = [:]
            if case .success(let output)? = call.result?.toolOutcome(Tools.AskUserQuestion.self) {
                answers = output.answers
            }
            appendEntry(
                .question(Question(call: call, questions: input?.questions ?? [], answers: answers)), at: date)
        } else if Tools.ExitPlanMode.matches(use.name) {
            var text = use.input(as: Tools.ExitPlanMode.self)?.plan
            if text == nil, case .success(let output)? = call.result?.toolOutcome(Tools.ExitPlanMode.self) {
                text = output.plan
            }
            appendEntry(.plan(Plan(call: call, text: text ?? "")), at: date)
        } else {
            flushNews()
            if runCalls.isEmpty { markVisible(at: date) }
            runCalls.append(call)
        }
    }

    private mutating func readNews(_ report: TaskReport, id: String, at date: Date?) {
        flushRun()
        if newsRun.isEmpty { markVisible(at: date) }
        let origin = report.toolUseID.flatMap { calls[$0] }
        let kind = TaskNews.Kind(report: report, origin: origin)
        let started = report.toolUseID.flatMap { callStarts[$0] }
        newsRun.append(
            TaskNews(
                id: id, report: report, kind: kind,
                line: writer.line(for: report, kind: kind, duration: Self.interval(from: started, to: date))))
    }

    private static func interval(from start: Date?, to end: Date?) -> TimeInterval? {
        guard let start, let end else { return nil }
        return max(0, end.timeIntervalSince(start))
    }

    // MARK: - Settling a call

    /// The call with its result and its state, as far as the transcript says.
    private func settle(_ use: ToolUseBlock, startedAt: Date?) -> ToolCall {
        let result = results[use.id]
        var call = ToolCall(
            use: use, result: result, kind: ToolKind(use, result: result), state: .done, startedAt: startedAt,
            finishedAt: result?.timestamp)
        call.state = state(of: call)
        if call.ranInBackground, let (report, at) = news[use.id], call.state == .background {
            call.finishedAt = at
            call.state = report.status.map(Self.isFailure) == true ? .failed(message: report.summary) : .done
        }
        return call
    }

    private func state(of call: ToolCall) -> ToolCallState {
        guard let result = call.result, let block = result.toolResult else {
            return tailCalls.contains(call.id) ? .running : .interrupted
        }
        if block.isError {
            let text = block.content.compactMap(\.text).joined(separator: "\n")
            if Self.deniedPrefixes.contains(where: text.hasPrefix) { return .denied }
            if Self.interruptedPrefixes.contains(where: text.hasPrefix) { return .interrupted }
            return .failed(message: text)
        }
        if case .success(let output)? = result.toolOutcome(Tools.Bash.self), Tools.Bash.matches(call.use.name) {
            if output.interrupted { return .interrupted }
            if output.backgroundTaskID != nil { return .background }
        }
        if Tools.Agent.matches(call.use.name), case .success(.launched)? = result.toolOutcome(Tools.Agent.self) {
            return .background
        }
        return .done
    }

    /// How the CLI words a call the reader or a permission rule refused.
    private static let deniedPrefixes = [
        "The user doesn't want to proceed with this tool use", "Permission for this action was denied",
        "Permission to use",
    ]

    private static let interruptedPrefixes = [
        "[Request interrupted", "Interrupted by user", "Tool permission request failed",
    ]

    private static func isFailure(_ status: TaskReport.Status) -> Bool {
        switch status {
        case .failed, .killed: true
        default: false
        }
    }

    // MARK: - Visible rows

    private mutating func appendEntry(_ entry: TranscriptEntry, at date: Date?) {
        flush()
        markVisible(at: date)
        entries.append(entry)
    }

    /// Something visible is about to start at `date`: after `/exit` it is a
    /// resumption, after a long silence a pause — either way a divider first.
    private mutating func markVisible(at date: Date?) {
        if exited {
            exited = false
            if let date {
                entries.append(.divider(SessionDivider(id: "resumed.\(entries.count)", kind: .resumed(date))))
            }
        } else if let date, let lastVisible, date.timeIntervalSince(lastVisible) > CorpusThresholds.pause {
            entries.append(.divider(SessionDivider(id: "pause.\(entries.count)", kind: .pause(date))))
        }
        if let date { lastVisible = date }
    }

    private mutating func flush() {
        flushRun()
        flushNews()
    }

    private mutating func flushRun() {
        guard !runCalls.isEmpty else { return }
        let items = items(of: runCalls)
        let duration = Self.interval(from: runCalls[0].startedAt, to: runCalls.compactMap(\.finishedAt).max())
        entries.append(
            .run(ToolRun(id: runCalls[0].id, items: items, line: writer.line(for: items, duration: duration))))
        runCalls = []
    }

    private mutating func flushNews() {
        guard !newsRun.isEmpty else { return }
        entries.append(.news(NewsRun(id: newsRun[0].id, news: newsRun, line: writer.line(for: newsRun))))
        newsRun = []
    }

    /// A run's calls as items: consecutive edits to one file are one.
    private func items(of calls: [ToolCall]) -> [RunItem] {
        var groups: [[ToolCall]] = []
        for call in calls {
            if call.kind == .change, let last = groups.last?.last, last.kind == .change,
                last.filePath != nil, last.filePath == call.filePath
            {
                groups[groups.count - 1].append(call)
            } else {
                groups.append([call])
            }
        }
        return groups.map { group in
            RunItem(calls: group, line: writer.line(for: group), error: writer.error(of: group))
        }
    }

    // MARK: - Folding into what came before

    /// A command's output joins its capsule; `/compact`'s and `/exit`'s
    /// fold away with them.
    private mutating func attachOutput(_ output: String, _ errorOutput: String) {
        if foldingCompact || exited { return }
        guard runCalls.isEmpty, newsRun.isEmpty, case .command(var command)? = entries.last,
            command.output.isEmpty, command.errorOutput.isEmpty
        else { return }
        command.output = output
        command.errorOutput = errorOutput
        entries[entries.count - 1] = .command(command)
    }

    private mutating func attachSummary(_ summary: String) {
        guard
            let index = entries.lastIndex(where: {
                if case .divider(let d) = $0, case .compacted = d.kind { true } else { false }
            }),
            case .divider(var divider) = entries[index]
        else { return }
        divider.summary = summary
        entries[index] = .divider(divider)
    }

    // MARK: - Names

    private func name(of sender: UserMessage.Sender) -> String {
        switch sender {
        case .agent(let id):
            agentNames[id] ?? String(localized: "Subagent \(String(id.prefix(7)))")
        case .session(let address, let name, _):
            name ?? address
        case .coordinator:
            String(localized: "Coordinator")
        case .plugin(let name):
            name
        }
    }
}
