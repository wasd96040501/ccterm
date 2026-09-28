import AgentSDK
import Foundation

nonisolated extension ToolStep {
    /// What a step needs from around it: which transcript it's in, and the
    /// background commands started before it, by task id, so reading one's
    /// output can say which command it was.
    struct Context: Sendable {
        var source: URL
        var backgroundCommands: [String: Tools.Bash.Input] = [:]
    }

    /// Reads `call` and the message answering it, if one was recorded.
    init(call: ToolUseBlock, result: UserMessage?, context: Context) {
        let reading = Reading(call: call, result: result, context: context)
        self = reading.step()
    }
}

/// The reading of one call, split out so each tool's case stays a few lines.
private nonisolated struct Reading {
    let call: ToolUseBlock
    let result: UserMessage?
    let context: Context

    typealias Context = ToolStep.Context

    /// How the call ended, and the CLI's message when it failed.
    var ending: (outcome: ToolStep.Outcome, message: String?) {
        guard let result, let block = result.toolResult else { return (.pending, nil) }
        guard block.isError || result.toolUseResult?.stringValue != nil else { return (.succeeded, nil) }
        let message = result.toolUseResult?.stringValue ?? block.content.compactMap(\.text).joined(separator: "\n")
        if message.contains("[Request interrupted by user") || message.contains("doesn't want to proceed")
            || message.contains("rejected")
        {
            return (.stopped, message)
        }
        return (.failed, message)
    }

    /// The result's text as the model saw it.
    var resultText: String {
        result?.toolResult?.content.compactMap(\.text).joined(separator: "\n") ?? ""
    }

    func document(_ title: String, _ symbol: String, _ content: ToolDocument.Content) -> ToolDocument {
        ToolDocument(
            id: ToolDocument.ID(transcript: context.source, key: call.id), title: title, symbol: symbol,
            content: content)
    }

    func step() -> ToolStep {
        if let input = call.input(as: Tools.Bash.self) { return bash(input) }
        if let input = call.input(as: Tools.Read.self) { return read(input) }
        if let input = call.input(as: Tools.Edit.self) { return edit(input) }
        if let input = call.input(as: Tools.Write.self) { return write(input) }
        if let input = call.input(as: Tools.Grep.self) { return grep(input) }
        if let input = call.input(as: Tools.Glob.self) { return glob(input) }
        if let input = call.input(as: Tools.WebFetch.self) { return webFetch(input) }
        if let input = call.input(as: Tools.WebSearch.self) { return webSearch(input) }
        if let input = call.input(as: Tools.Agent.self) { return agent(input) }
        if let input = call.input(as: Tools.TodoWrite.self) { return todos(input) }
        if let input = call.input(as: Tools.ExitPlanMode.self) { return plan(input.plan) }
        if let input = call.input(as: Tools.NotebookEdit.self) { return notebookEdit(input) }
        switch call.name {
        case "MultiEdit": return multiEdit()
        case "BashOutput", "TaskOutput": return commandOutput()
        case "TaskStop", "KillShell", "KillBash": return stop()
        case "EnterPlanMode":
            return base(.other, "list.bullet.clipboard", String(localized: "Entered plan mode"))
        default: return other()
        }
    }

    // MARK: - Shell

    private func bash(_ input: Tools.Bash.Input) -> ToolStep {
        let firstLine = input.command.firstLine
        let summary = input.description?.nilIfBlank
        var step = base(.command, "terminal", summary ?? firstLine)
        step.detail = summary == nil ? nil : firstLine
        step.detailIsCode = true
        var status = ToolDocument.Command.Status.unknown
        var output = ""
        var errorOutput = ""
        switch result?.toolOutcome(Tools.Bash.self) {
        case .success(let recorded)?:
            output = recorded.stdout
            errorOutput = recorded.stderr
            if recorded.interrupted {
                status = .interrupted
                step.outcome = .stopped
                step.stat = .note(String(localized: "Interrupted"))
            } else if recorded.backgroundTaskID != nil {
                status = .running
                step.stat = .note(String(localized: "In Background"))
            } else {
                status = .succeeded
            }
        case .failure(let message)?:
            let code = message.exitCode
            status = step.outcome == .stopped ? .interrupted : .failed(exitCode: code)
            output = message.droppingExitCodeLine
            if let code { step.stat = .note(String(localized: "Exit \(code)")) }
        case .unavailable?:
            output = resultText
            status = .succeeded
        case nil:
            break
        }
        step.document = document(
            summary ?? firstLine, "terminal",
            .command(
                .init(
                    command: input.command, description: summary, output: output, errorOutput: errorOutput,
                    status: status)))
        return step
    }

    /// `BashOutput` (older CLIs) and `TaskOutput`: a background task's output
    /// so far, shown as the command it came from when that is known.
    private func commandOutput() -> ToolStep {
        let taskID = call.input["task_id"]?.stringValue ?? call.input["bash_id"]?.stringValue ?? ""
        let origin = context.backgroundCommands[taskID]
        let recorded = result?.toolUseResult
        let task = recorded?["task"]
        let taskDescription = task?["description"]?.stringValue ?? origin?.description
        let title =
            taskDescription?.nilIfBlank.map { String(localized: "Output of “\($0)”") }
            ?? String(localized: "Background Output")
        var step = base(.command, "text.below.photo", title)
        step.detail = origin.map(\.command.firstLine) ?? recorded?["command"]?.stringValue?.firstLine
        step.detailIsCode = true
        let output =
            task?["output"]?.stringValue ?? recorded?["stdout"]?.stringValue ?? (ending.message ?? resultText)
        let errorOutput = recorded?["stderr"]?.stringValue ?? ""
        let exitCode = task?["exitCode"]?.intValue ?? recorded?["exitCode"]?.intValue
        let state = task?["status"]?.stringValue ?? recorded?["status"]?.stringValue
        let status: ToolDocument.Command.Status
        switch state {
        case "completed": status = exitCode.map { $0 == 0 ? .succeeded : .failed(exitCode: $0) } ?? .succeeded
        case "failed": status = .failed(exitCode: exitCode)
        case "running": status = .running
        case "killed", "stopped": status = .interrupted
        default: status = .unknown
        }
        if case .failed(let code?) = status { step.stat = .note(String(localized: "Exit \(code)")) }
        if status == .running { step.stat = .note(String(localized: "Running")) }
        step.document = document(
            taskDescription ?? title, "terminal",
            .command(
                .init(
                    command: origin?.command ?? recorded?["command"]?.stringValue, description: taskDescription,
                    output: output, errorOutput: errorOutput, status: status)))
        return step
    }

    private func stop() -> ToolStep {
        let taskID = call.input["task_id"]?.stringValue ?? call.input["shell_id"]?.stringValue ?? ""
        let origin = context.backgroundCommands[taskID]
        var step = base(.command, "stop.circle", String(localized: "Stopped a background task"))
        step.detail = origin?.description ?? origin.map(\.command.firstLine) ?? taskID.nilIfBlank
        step.detailIsCode = origin?.description == nil
        return step
    }

    // MARK: - Files

    private func read(_ input: Tools.Read.Input) -> ToolStep {
        var step = base(.read, "doc.text", input.filePath.fileName)
        step.detail = input.filePath.folder
        switch result?.toolOutcome(Tools.Read.self) {
        case .success(.text(let file))?:
            let last = file.startLine + max(0, file.numLines - 1)
            if file.numLines > 0, file.numLines < file.totalLines {
                step.stat = .note(String(localized: "Lines \(file.startLine)–\(last)"))
            }
            step.document = document(
                input.filePath.fileName, "doc.text",
                .file(path: input.filePath, text: file.content, firstLine: file.startLine))
        case .success(.image)?:
            step.stat = .note(String(localized: "Image"))
        case .success(.pdf)?:
            step.stat = .note(String(localized: "PDF"))
        case .success(.unchanged)?:
            step.stat = .note(String(localized: "Unchanged"))
        default:
            break
        }
        return step
    }

    private func edit(_ input: Tools.Edit.Input) -> ToolStep {
        var step = base(.edit, "pencil", input.filePath.fileName)
        step.detail = input.filePath.folder
        let content: ToolDocument.Content
        if case .success(let output)? = result?.toolOutcome(Tools.Edit.self), !output.structuredPatch.isEmpty {
            content = .comparison(path: input.filePath, hunks: output.structuredPatch, original: output.originalFile)
            step.stat = output.structuredPatch.lineStat
        } else {
            content = .replacement(path: input.filePath, old: input.oldString, new: input.newString)
            step.stat = lineStat(old: input.oldString, new: input.newString)
        }
        step.document = document(input.filePath.fileName, "pencil", content)
        return step
    }

    private func multiEdit() -> ToolStep {
        let path = call.input["file_path"]?.stringValue ?? ""
        var step = base(.edit, "pencil", path.fileName)
        step.detail = path.folder
        if case .success(let output)? = result?.toolOutcome(Tools.Edit.self), !output.structuredPatch.isEmpty {
            step.stat = output.structuredPatch.lineStat
            step.document = document(
                path.fileName, "pencil",
                .comparison(path: path, hunks: output.structuredPatch, original: output.originalFile))
        }
        return step
    }

    private func write(_ input: Tools.Write.Input) -> ToolStep {
        var step = base(.edit, "doc.badge.plus", input.filePath.fileName)
        step.detail = input.filePath.folder
        if case .success(let output)? = result?.toolOutcome(Tools.Write.self), !output.isNewFile,
            !output.structuredPatch.isEmpty
        {
            step.symbol = "pencil"
            step.stat = output.structuredPatch.lineStat
            step.document = document(
                input.filePath.fileName, "pencil",
                .comparison(path: input.filePath, hunks: output.structuredPatch, original: output.originalFile))
        } else {
            step.stat = .lines(added: input.content.lineCount, removed: 0)
            step.document = document(
                input.filePath.fileName, "doc.badge.plus",
                .file(path: input.filePath, text: input.content, firstLine: 1))
        }
        return step
    }

    private func notebookEdit(_ input: Tools.NotebookEdit.Input) -> ToolStep {
        var step = base(.edit, "book.pages", input.notebookPath.fileName)
        step.detail = input.notebookPath.folder
        step.document = document(input.notebookPath.fileName, "book.pages", .text(input.newSource))
        return step
    }

    // MARK: - Search

    private func grep(_ input: Tools.Grep.Input) -> ToolStep {
        var step = base(.search, "magnifyingglass", input.pattern)
        step.detail =
            [input.path?.abbreviatingHome, input.glob ?? input.type].compactMap { $0 }.joined(separator: " · ")
            .nilIfBlank
        if case .success(let output)? = result?.toolOutcome(Tools.Grep.self) {
            if let matches = output.numMatches ?? output.numLines, output.content != nil {
                step.stat = .note(String(localized: "\(matches) matches"))
            } else {
                step.stat = .note(Self.files(output.numFiles))
            }
            let listing = output.content?.nilIfBlank ?? output.filenames.joined(separator: "\n")
            step.document = document(input.pattern, "magnifyingglass", .text(listing))
        }
        return step
    }

    private func glob(_ input: Tools.Glob.Input) -> ToolStep {
        var step = base(.search, "magnifyingglass", input.pattern)
        step.detail = input.path?.abbreviatingHome
        if case .success(let output)? = result?.toolOutcome(Tools.Glob.self) {
            step.stat = .note(Self.files(output.numFiles))
            step.document = document(input.pattern, "magnifyingglass", .text(output.filenames.joined(separator: "\n")))
        }
        return step
    }

    private static func files(_ count: Int) -> String {
        count == 1 ? String(localized: "1 file") : String(localized: "\(count) files")
    }

    // MARK: - Web

    private func webFetch(_ input: Tools.WebFetch.Input) -> ToolStep {
        let url = URL(string: input.url)
        var step = base(.web, "globe", url?.host() ?? input.url)
        step.detail = url.map { $0.path().nilIfBlank ?? "/" }
        if case .success(let output)? = result?.toolOutcome(Tools.WebFetch.self) {
            if output.code >= 400 { step.stat = .note("\(output.code)") }
            step.document = document(url?.host() ?? input.url, "globe", .markdown(output.result))
        }
        return step
    }

    private func webSearch(_ input: Tools.WebSearch.Input) -> ToolStep {
        var step = base(.web, "globe", input.query)
        if case .success(let output)? = result?.toolOutcome(Tools.WebSearch.self) {
            step.stat = .note(
                output.links.count == 1
                    ? String(localized: "1 result") : String(localized: "\(output.links.count) results"))
            let links = output.links.map { "- [\($0.title)](\($0.url))" }.joined(separator: "\n")
            let summaries = output.summaries.joined(separator: "\n\n")
            step.document = document(
                input.query, "globe", .markdown([links, summaries].filter { !$0.isEmpty }.joined(separator: "\n\n")))
        }
        return step
    }

    // MARK: - Agents and plans

    private func agent(_ input: Tools.Agent.Input) -> ToolStep {
        var step = base(.agent, "person.2", input.description.nilIfBlank ?? String(localized: "Subagent"))
        step.detail = input.subagentType
        var report: String?
        switch result?.toolOutcome(Tools.Agent.self) {
        case .success(.completed(let completed))?:
            report = completed.text
            step.stat = .note(
                completed.totalToolUseCount == 1
                    ? String(localized: "1 tool use") : String(localized: "\(completed.totalToolUseCount) tool uses"))
        case .success(.launched)?:
            step.stat = .note(String(localized: "In Background"))
        case .unavailable?:
            report = resultText
        default:
            break
        }
        let promptHeading = String(localized: "Prompt")
        let reportHeading = String(localized: "Report")
        var markdown = "## \(promptHeading)\n\n\(input.prompt)"
        if let report = report?.nilIfBlank { markdown += "\n\n## \(reportHeading)\n\n\(report)" }
        step.document = document(step.title, "person.2", .markdown(markdown))
        return step
    }

    private func todos(_ input: Tools.TodoWrite.Input) -> ToolStep {
        var step = base(.other, "checklist", String(localized: "Updated the to-do list"))
        let done = input.todos.filter { $0.status == .completed }.count
        step.detail = String(localized: "\(done) of \(input.todos.count) done")
        let list = input.todos.map { "- [\($0.status == .completed ? "x" : " ")] \($0.content)" }
            .joined(separator: "\n")
        step.document = document(String(localized: "To-Do List"), "checklist", .markdown(list))
        return step
    }

    private func plan(_ plan: String?) -> ToolStep {
        var step = base(.other, "list.bullet.clipboard", String(localized: "Presented a plan"))
        if let plan = plan?.nilIfBlank {
            step.detail = plan.firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            step.document = document(String(localized: "Plan"), "list.bullet.clipboard", .markdown(plan))
        }
        return step
    }

    // MARK: - Anything else

    /// A tool this app doesn't know: its name, its first string argument, and
    /// its raw input and output to open.
    private func other() -> ToolStep {
        var step = base(.other, "wrench.and.screwdriver", call.name.toolDisplayName)
        if case .object(let fields) = call.input {
            step.detail = fields.keys.sorted().lazy.compactMap { fields[$0]?.stringValue?.firstLine.nilIfBlank }.first
        }
        let input = call.input.prettyPrinted
        let output = ending.message ?? resultText
        step.document = document(
            step.title, "wrench.and.screwdriver",
            .text([input, output].filter { !$0.isEmpty }.joined(separator: "\n\n")))
        return step
    }

    private func base(_ kind: ToolStep.Kind, _ symbol: String, _ title: String) -> ToolStep {
        ToolStep(id: call.id, kind: kind, symbol: symbol, title: title, outcome: ending.outcome)
    }

    private func lineStat(old: String, new: String) -> ToolStep.Stat {
        let difference = new.lines.difference(from: old.lines)
        return .lines(added: difference.insertions.count, removed: difference.removals.count)
    }
}

// MARK: - Reading helpers

nonisolated extension [DiffHunk] {
    fileprivate var lineStat: ToolStep.Stat {
        let lines = flatMap(\.lines)
        return .lines(
            added: lines.filter { $0.hasPrefix("+") }.count, removed: lines.filter { $0.hasPrefix("-") }.count)
    }
}

nonisolated extension String {
    fileprivate var firstLine: String {
        let trimmed = drop(while: \.isNewline)
        return String(trimmed.prefix { !$0.isNewline })
    }

    fileprivate var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }

    fileprivate var fileName: String { (self as NSString).lastPathComponent }

    /// The folder holding this path, with the home folder as `~`.
    fileprivate var folder: String? {
        let folder = (self as NSString).deletingLastPathComponent
        return folder.isEmpty ? nil : folder.abbreviatingHome
    }

    fileprivate var abbreviatingHome: String { (self as NSString).abbreviatingWithTildeInPath }

    fileprivate var lines: [String] { components(separatedBy: "\n") }

    fileprivate var lineCount: Int {
        isEmpty ? 0 : lines.count - (hasSuffix("\n") ? 1 : 0)
    }

    /// The code in a failed command's `Exit code 1` first line.
    fileprivate var exitCode: Int? {
        guard hasPrefix("Exit code ") else { return nil }
        return Int(firstLine.dropFirst("Exit code ".count).trimmingCharacters(in: .whitespaces))
    }

    fileprivate var droppingExitCodeLine: String {
        guard exitCode != nil, let newline = firstIndex(of: "\n") else { return exitCode == nil ? self : "" }
        return String(self[index(after: newline)...])
    }

    /// `mcp__github__create_issue` → `github · create_issue`.
    fileprivate var toolDisplayName: String {
        guard hasPrefix("mcp__") else { return self }
        let parts = dropFirst("mcp__".count).components(separatedBy: "__")
        return parts.joined(separator: " · ")
    }
}

nonisolated extension JSONValue {
    fileprivate var prettyPrinted: String {
        guard let data = try? JSONEncoder.pretty.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

nonisolated extension JSONEncoder {
    fileprivate static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
