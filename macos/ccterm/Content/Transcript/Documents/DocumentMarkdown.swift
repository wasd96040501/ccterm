import AgentSDK
import DisplayModels
import Foundation

/// The markdown of a document that is words rather than code — a search, a
/// page fetched, an agent's report, the task list (a `- [x]` checklist as it
/// stood after that call), a task's news, a command's output, a
/// compaction's summary, a session's log and its context, any other call. TranscriptKit sets it, so find,
/// selection and copy work in it as in a reply.
///
/// Every document opens with its title as a heading and a status line under
/// it, then its body (design/transcript/preview.js `markdownDoc`); the title
/// is the header's, so the bar and the page say the same words.
nonisolated enum DocumentMarkdown {
    static func markdown(for content: DocumentContent) -> String {
        let title = DocumentHeader.markdown(content).title
        var blocks: [String] = []
        let (heading, status, body) = parts(of: content, title: title)
        blocks.append("### " + escaped(heading))
        if !status.isEmpty { blocks.append("*" + escaped(status.joined(separator: " · ")) + "*") }
        blocks.append(contentsOf: body.filter { !$0.isEmpty })
        return blocks.joined(separator: "\n\n")
    }

    /// The heading, the status line's parts, and the body's blocks.
    private static func parts(of content: DocumentContent, title: String) -> (String, [String], [String]) {
        switch content {
        case .search(let call):
            let term = DocumentHeader.searchTerm(call)
            return (String(localized: "“\(term)”"), searchStatus(call), searchBody(call))
        case .web(let call):
            return (title, webStatus(call), webBody(call))
        case .agent(let call):
            let (status, body) = agent(call)
            return (title, status, [body])
        case .agentMessage(let message):
            return (title, [], [message.text])
        case .taskList(let items):
            return (title, [], [checklist(items)])
        case .news(_, let report):
            return (title, newsStatus(report), newsBody(report))
        case .commandOutput(let command):
            let output = command.outputIsError ? command.errorOutput : command.output
            return (
                ([command.title, command.arguments].filter { !$0.isEmpty }).joined(separator: " "),
                [String(localized: "Local command output")], [fenced(output.trimmingCharacters(in: .newlines))]
            )
        case .log(let failure):
            return (title, [failure.message], [logBody(failure)])
        case .contextUsage(let usage):
            return (title, [usage.model].compactMap { $0 }, contextBody(usage))
        case .compactionSummary(let summary):
            return (title, [String(localized: "What the model continued from")], [summary])
        case .advice(let call):
            return (title, [call.advisor?.model].compactMap { $0 }, [call.advisor?.advice ?? ""])
        case .sentMessage(let call):
            let message = call.sentMessage
            return (title, [message?.summary ?? ""].filter { !$0.isEmpty }, [message?.body ?? ""])
        case .continuationPrompt(let text):
            return (title, [String(localized: "Written by Claude Code, not by you")], [text])
        case .other(let call):
            return (title, otherStatus(call), other(call))
        case .command, .shellCommand, .change, .newFile, .read, .image:
            // Not words; their own bodies show them.
            return (title, [], [])
        }
    }

    // MARK: - Search

    private static func searchStatus(_ call: ToolCall) -> [String] {
        var status = [
            call.use.input["path"]?.stringValue.map { String(localized: "in \($0)") }
                ?? String(localized: "in the project")
        ]
        let count = DocumentHeader.markdown(.search(call)).stat.string
        if !count.isEmpty { status.append(count) }
        return status
    }

    /// The files that matched, each with the folder it is in (and, when the
    /// search counted, how many matches); a search that printed lines is those
    /// lines.
    private static func searchBody(_ call: ToolCall) -> [String] {
        func files(_ names: [String]) -> String {
            names.map { path in
                let name = (path as NSString).lastPathComponent
                let folder = (path as NSString).deletingLastPathComponent
                return "- **\(escaped(name))** " + (folder.isEmpty ? "" : "`\(folder)`")
            }.joined(separator: "\n")
        }
        if Tools.Grep.matches(call.use.name) {
            switch call.result?.toolOutcome(Tools.Grep.self) {
            case .success(let output)?:
                if let content = output.content, !content.isEmpty { return [fenced(content)] }
                return [files(output.filenames)]
            case .failure(let message)?: return [fenced(message)]
            case .unavailable?: return [fenced(modelText(call))]
            case nil: return []
            }
        }
        if Tools.Glob.matches(call.use.name) {
            switch call.result?.toolOutcome(Tools.Glob.self) {
            case .success(let output)?: return [files(output.filenames)]
            case .failure(let message)?: return [fenced(message)]
            case .unavailable?: return [fenced(modelText(call))]
            case nil: return []
            }
        }
        return [fenced(modelText(call))]
    }

    // MARK: - Web

    private static func webStatus(_ call: ToolCall) -> [String] {
        if Tools.WebSearch.matches(call.use.name) {
            if case .success(let output)? = call.result?.toolOutcome(Tools.WebSearch.self) {
                let count = output.links.count
                return [count == 1 ? String(localized: "1 result") : String(localized: "\(count) results")]
            }
            return []
        }
        var status = [call.use.input["url"]?.stringValue].compactMap { $0 }
        if case .success(let output)? = call.result?.toolOutcome(Tools.WebFetch.self),
            Tools.WebFetch.matches(call.use.name)
        {
            status.append("\(output.code) \(output.codeText)".trimmingCharacters(in: .whitespaces))
        }
        return status
    }

    private static func webBody(_ call: ToolCall) -> [String] {
        if Tools.WebSearch.matches(call.use.name) {
            switch call.result?.toolOutcome(Tools.WebSearch.self) {
            case .success(let output)?:
                let links = output.links.map { "- [\(escaped($0.title))](\($0.url))" }.joined(separator: "\n")
                return [links] + output.summaries
            case .failure(let message)?: return [fenced(message)]
            case .unavailable?: return [modelText(call)]
            case nil: return []
            }
        }
        switch call.result?.toolOutcome(Tools.WebFetch.self) {
        case .success(let output)? where Tools.WebFetch.matches(call.use.name): return [output.result]
        case .failure(let message)?: return [fenced(message)]
        case .success?, .unavailable?: return [modelText(call)]
        case nil: return []
        }
    }

    // MARK: - Agent

    private static func agent(_ call: ToolCall) -> (status: [String], body: String) {
        var status = [call.use.input["subagent_type"]?.stringValue].compactMap { $0 }
        switch call.result?.toolOutcome(Tools.Agent.self) {
        case .success(.completed(let done))?:
            let time = (TimeInterval(done.totalDurationMS) / 1000).durationText
            status.append(String(localized: "\(done.totalToolUseCount) tools · \(time)"))
            return (status, done.text)
        case .success(.launched)?:
            return (status, String(localized: "The agent is working in the background."))
        case .failure(let message)?:
            return (status, fenced(message))
        case .success(.other)?, .unavailable?:
            return (status, modelText(call))
        case nil:
            return (status, String(localized: "The agent is still working."))
        }
    }

    // MARK: - Task list

    /// The list as it stood: done items struck through, the rest open.
    private static func checklist(_ items: [TaskListItem]) -> String {
        items.map { item -> String in
            let subject = escaped(item.subject)
            switch item.status {
            case .completed: return "- [x] ~~\(subject)~~"
            case .inProgress: return "- [ ] **\(subject)**"
            case .pending: return "- [ ] \(subject)"
            }
        }.joined(separator: "\n")
    }

    // MARK: - News

    /// What the task used, and where it worked: *general-purpose · 14 tools ·
    /// 2m 10s · .claude/worktrees/review · review-diff*.
    private static func newsStatus(_ report: TaskReport) -> [String] {
        var status: [String] = []
        if let usage = report.usage {
            if let agents = usage.agentCount {
                status.append(String(localized: "\(agents) agents"))
                if let done = usage.agentsDone { status.append(String(localized: "\(done) done")) }
                if let failed = usage.agentsFailed, failed > 0 { status.append(String(localized: "\(failed) failed")) }
            } else if let tools = usage.totalToolUseCount {
                if let ms = usage.totalDurationMS {
                    status.append(
                        String(localized: "\(tools) tools · \((TimeInterval(ms) / 1000).durationText)"))
                } else {
                    status.append(String(localized: "\(tools) tools"))
                }
            }
        }
        if report.event != nil, status.isEmpty { status.append(String(localized: "Monitor event")) }
        if let path = report.worktreePath { status.append(path) }
        if let branch = report.worktreeBranch { status.append(branch) }
        return status
    }

    /// The failures and the way to recover, when there are any, above the
    /// result; a monitor's event.
    private static func newsBody(_ report: TaskReport) -> [String] {
        if let event = report.event { return [event] }
        var body: [String] = []
        if let failures = report.failures, !failures.isEmpty {
            body += ["**\(String(localized: "Failures"))**", failures]
        }
        if let recovery = report.recovery, !recovery.isEmpty {
            body += ["**\(String(localized: "Recovery"))**", recovery]
        }
        if let result = report.result, !result.isEmpty {
            if !body.isEmpty { body.append("**\(String(localized: "Result"))**") }
            body.append(result)
        }
        if body.isEmpty { body.append(report.summary) }
        return body
    }

    // MARK: - Any other call

    private static func otherStatus(_ call: ToolCall) -> [String] {
        let name = call.toolName
        return name.server == name.tool ? [] : [name.server]
    }

    /// What was asked and what came back, as they were recorded.
    private static func other(_ call: ToolCall) -> [String] {
        var body = ["**\(String(localized: "Input"))**", fenced(prettyJSON(call.use.input), language: "json")]
        if call.result != nil {
            body += ["**\(String(localized: "Result"))**", fenced(modelText(call))]
        }
        return body
    }

    // MARK: - Pieces

    /// The model-facing text of the call's result.
    private static func modelText(_ call: ToolCall) -> String {
        guard let result = call.result?.toolResult else { return "" }
        return result.content.compactMap(\.text).joined(separator: "\n")
    }

    private static func prettyJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    /// A fenced block whose fence is longer than any run of backticks inside.
    static func fenced(_ text: String, language: String = "") -> String {
        guard !text.isEmpty else { return "" }
        var longest = 0
        var run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "\(fence)\(language)\n\(text)\n\(fence)"
    }

    /// Words shown as they are, not read as markdown.
    static func escaped(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\`*_[]<>~".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}
