import AgentSDK
import Foundation

/// Words every work line: a run's sentence, an item's label, a task's news
/// (design/transcript/01-run.md "The sentence", "A run of one is the call
/// itself", "Expanded", "Live"; 04-background.md "The row").
///
/// Pure: calls in, `WorkLine` out, localized. The page calls it once per
/// line when it is built, never while drawing.
nonisolated struct WorkLineWriter {
    /// The session's working directory: a path under it is shown relative to
    /// it — the part a reader recognises.
    let workingDirectory: String?

    // MARK: - A run

    /// The collapsed row of a run. One item is named on its own; more are
    /// counted in a sentence.
    func line(for items: [RunItem], duration: TimeInterval?) -> WorkLine {
        let calls = items.flatMap(\.calls)
        if items.count == 1 {
            var line = line(for: items[0].calls, standalone: true)
            line.tile = runTile(items)
            return line
        }
        return WorkLine(
            tile: runTile(items), text: liveSentence(calls) ?? sentence(items), detail: nil,
            exceptions: exceptions(calls),
            meta: runMeta(calls, duration: duration, live: calls.contains { $0.state.isLive }))
    }

    /// The tile shows how the run ended — or, live, the call going on now.
    func runTile(_ items: [RunItem]) -> Tile {
        let calls = items.flatMap(\.calls)
        if let live = calls.last(where: { $0.state.isLive && $0.state != .background }) {
            return Tile(glyph: .tool(live.kind), state: Self.tileState(live.state))
        }
        if let last = items.last, [.failed, .stopped].contains(Self.tileState(last.state)) {
            return Tile(glyph: .tool(last.kind), state: Self.tileState(last.state))
        }
        let kind = calls.map(\.kind).min() ?? .other
        return Tile(glyph: .tool(kind), state: calls.contains { $0.state == .background } ? .background : .done)
    }

    /// What a live run is doing now; `nil` once nothing is.
    private func liveSentence(_ calls: [ToolCall]) -> StyledText? {
        if calls.contains(where: { if case .waiting = $0.state { true } else { false } }) {
            return StyledText(String(localized: "Waiting for your approval"))
        }
        let running = calls.filter { $0.state == .running }
        if running.count > 1 {
            return running.allSatisfy({ $0.kind == .command })
                ? StyledText(String(localized: "Running \(running.count) commands"))
                : StyledText(String(localized: "Running \(running.count) calls"))
        }
        if let call = running.first ?? calls.first(where: { $0.state == .preparing }) {
            return liveLabel(call)
        }
        return nil
    }

    /// Clauses in kind order, at most three, then *and N more*.
    func sentence(_ items: [RunItem]) -> StyledText {
        var clauses = clauses(items)
        guard !clauses.isEmpty else {
            let count = items.flatMap(\.calls).count
            return StyledText(count == 1 ? String(localized: "1 call") : String(localized: "\(count) calls"))
        }
        let more = clauses.count - CorpusThresholds.clauses
        clauses = Array(clauses.prefix(CorpusThresholds.clauses))
        for index in clauses.indices.dropFirst() { clauses[index] = Self.lowercasingFirst(clauses[index]) }
        var sentence = StyledText.joined(
            clauses, separator: String(localized: ", ", comment: "Between clauses of a work summary"))
        if more > 0 {
            sentence.append(StyledText(String(localized: ", and \(more) more")))
        }
        return sentence
    }

    /// Clauses count what took effect: a denied call did nothing, and a
    /// failed edit changed no file. A failed command still ran.
    private func clauses(_ items: [RunItem]) -> [StyledText] {
        let effective = items.filter { item in
            switch item.state {
            case .denied: false
            case .failed: item.kind != .change && item.kind != .create
            default: true
            }
        }
        // The cases are in the sentence's order.
        return ToolKind.allCases.flatMap { kind in clauses(of: kind, effective.filter { $0.kind == kind }) }
    }

    /// What `items`, all of `kind`, add to a run's sentence: nothing, a
    /// clause, or — for other tools — one per MCP server.
    private func clauses(of kind: ToolKind, _ items: [RunItem]) -> [StyledText] {
        let calls = items.flatMap(\.calls)
        guard !calls.isEmpty else { return [] }
        switch kind {
        case .change:
            return files(
                items,
                one: { StyledText(localized: String(localized: "Edited \(StyledText.slot(0))"), $0) },
                two: {
                    StyledText(
                        localized: String(localized: "Edited \(StyledText.slot(0)) and \(StyledText.slot(1))"), $0, $1)
                },
                many: { StyledText(String(localized: "Edited \($0) files")) }
            ).map { [$0] } ?? []
        case .create:
            return files(
                items,
                one: { StyledText(localized: String(localized: "Created \(StyledText.slot(0))"), $0) },
                two: {
                    StyledText(
                        localized: String(localized: "Created \(StyledText.slot(0)) and \(StyledText.slot(1))"), $0, $1)
                },
                many: { StyledText(String(localized: "Created \($0) files")) }
            ).map { [$0] } ?? []
        case .command:
            return [
                calls.count == 1
                    ? StyledText(String(localized: "Ran a command"))
                    : StyledText(String(localized: "Ran \(calls.count) commands"))
            ]
        case .agent:
            return [
                calls.count == 1
                    ? StyledText(String(localized: "Ran an agent"))
                    : StyledText(String(localized: "Ran \(calls.count) agents"))
            ]
        case .web:
            let searches = calls.filter { Tools.WebSearch.matches($0.use.name) }.count
            let fetches = calls.count - searches
            switch (searches > 0, fetches) {
            case (true, 0): return [StyledText(String(localized: "Searched the web"))]
            case (true, 1): return [StyledText(String(localized: "Searched the web and fetched a page"))]
            case (true, let n): return [StyledText(String(localized: "Searched the web and fetched \(n) pages"))]
            case (false, 1): return [StyledText(String(localized: "Fetched a page"))]
            case (false, let n): return [StyledText(String(localized: "Fetched \(n) pages"))]
            }
        case .search:
            if calls.count == 1, let pattern = calls[0].use.input["pattern"]?.stringValue {
                return [
                    StyledText(
                        localized: String(localized: "Searched for \(StyledText.slot(0))"),
                        StyledText(pattern, style: .code))
                ]
            }
            return [StyledText(String(localized: "Searched \(calls.count) times"))]
        case .read:
            return files(
                items,
                one: { StyledText(localized: String(localized: "Read \(StyledText.slot(0))"), $0) },
                two: {
                    StyledText(
                        localized: String(localized: "Read \(StyledText.slot(0)) and \(StyledText.slot(1))"), $0, $1)
                },
                many: { StyledText(String(localized: "Read \($0) files")) }
            ).map { [$0] } ?? []
        case .tasks:
            return [StyledText(String(localized: "Updated the task list"))]
        case .schedule:
            return [
                calls.count == 1
                    ? StyledText(String(localized: "Scheduled a task"))
                    : StyledText(String(localized: "Scheduled \(calls.count) tasks"))
            ]
        case .message:
            return [
                calls.count == 1
                    ? StyledText(String(localized: "Sent a message"))
                    : StyledText(String(localized: "Sent \(calls.count) messages"))
            ]
        case .other:
            var servers: [(String, Int)] = []
            for call in calls {
                let server = Self.toolName(call.use.name).server
                if let index = servers.firstIndex(where: { $0.0 == server }) {
                    servers[index].1 += 1
                } else {
                    servers.append((server, 1))
                }
            }
            return servers.map { server, count in
                count == 1
                    ? StyledText(String(localized: "Used \(server) once"))
                    : StyledText(String(localized: "Used \(server) \(count) times"))
            }
        }
    }

    /// A clause about files: named when there are at most two (each a link
    /// to its item), counted otherwise. The same file counts once.
    private func files(
        _ items: [RunItem], one: (StyledText) -> StyledText, two: (StyledText, StyledText) -> StyledText,
        many: (Int) -> StyledText
    ) -> StyledText? {
        var seen: [String: RunItem] = [:]
        var order: [String] = []
        for item in items {
            let path = item.calls[0].filePath ?? item.id
            if seen[path] == nil {
                seen[path] = item
                order.append(path)
            }
        }
        func noun(_ path: String) -> StyledText {
            StyledText(Self.fileName(path), style: .noun(opens: seen[path]?.id))
        }
        switch order.count {
        case 0: return nil
        case 1: return one(noun(order[0]))
        case CorpusThresholds.namedFiles: return two(noun(order[0]), noun(order[1]))
        default: return many(order.count)
        }
    }

    /// Set apart from the sentence, never cut: *· 1 failed · Interrupted*.
    func exceptions(_ calls: [ToolCall]) -> StyledText {
        var parts: [StyledText] = []
        let failed = calls.filter { if case .failed = $0.state { true } else { false } }.count
        if failed > 0 { parts.append(StyledText(String(localized: "\(failed) failed"), style: .failure)) }
        let denied = calls.filter { $0.state == .denied }.count
        if denied > 0 { parts.append(StyledText(String(localized: "\(denied) denied"))) }
        if calls.contains(where: { $0.state == .interrupted }) {
            parts.append(StyledText(String(localized: "Interrupted")))
        }
        let background = calls.filter { $0.state == .background }.count
        if background > 0 { parts.append(StyledText(String(localized: "\(background) in background"))) }
        return StyledText.joined(parts.map { StyledText("· ") + $0 }, separator: " ")
    }

    /// Lines added and removed when the run changed files; its wall time when
    /// that is worth noticing.
    private func runMeta(_ calls: [ToolCall], duration: TimeInterval?, live: Bool) -> StyledText {
        var parts: [StyledText] = []
        let changed = calls.filter { ($0.kind == .change || $0.kind == .create) && $0.state == .done }
        if !changed.isEmpty {
            let stats = changed.compactMap(Self.diffStat)
            parts.append(Self.stat(added: stats.map(\.added).reduce(0, +), removed: stats.map(\.removed).reduce(0, +)))
        }
        if !live, let duration, duration >= CorpusThresholds.shownDuration {
            parts.append(StyledText(Self.format(duration)))
        }
        return StyledText.joined(parts, separator: "  ")
    }

    // MARK: - An item

    /// An item of an expanded run — or, `standalone`, a run of one, which
    /// names the call as a sentence (*Edited **A.swift***) rather than as a
    /// list entry (***A.swift** folder*).
    func line(for calls: [ToolCall], standalone: Bool = false) -> WorkLine {
        let call = calls[calls.count - 1]
        let first = calls[0]
        var line = WorkLine(
            tile: Tile(glyph: .tool(first.kind), state: Self.tileState(call.state)), text: StyledText(), detail: nil,
            exceptions: StyledText(), meta: itemMeta(calls))
        switch call.state {
        case .running, .preparing:
            line.text = liveLabel(call)
        default:
            (line.text, line.detail) = label(first, standalone: standalone, opens: first.id)
        }
        return line
    }

    /// The first line of what went wrong, shown in red under a failed item.
    func error(of calls: [ToolCall]) -> String? {
        guard case .failed(let message) = calls[calls.count - 1].state else { return nil }
        let lines = message.replacingOccurrences(of: "<tool_use_error>", with: "")
            .replacingOccurrences(of: "</tool_use_error>", with: "")
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.first { !$0.hasPrefix("Exit code ") } ?? lines.first
    }

    /// A call named on its own: the label, and the detail after it.
    private func label(_ call: ToolCall, standalone: Bool, opens: String) -> (StyledText, String?) {
        let input = call.use.input
        switch call.kind {
        case .command:
            let command = input["command"]?.stringValue ?? ""
            if let description = input["description"]?.stringValue, !description.isEmpty {
                return (StyledText(description), Self.firstLine(Self.strippingDirectoryChange(command)))
            }
            return (StyledText(Self.firstLine(command), style: .code), nil)
        case .change, .create, .read:
            let path = call.filePath ?? ""
            guard standalone else {
                return (StyledText(Self.fileName(path), style: .noun(opens: nil)), folder(path))
            }
            let file = StyledText(Self.fileName(path), style: .noun(opens: opens))
            switch call.kind {
            case .change: return (StyledText(localized: String(localized: "Edited \(StyledText.slot(0))"), file), nil)
            case .create: return (StyledText(localized: String(localized: "Created \(StyledText.slot(0))"), file), nil)
            default: return (StyledText(localized: String(localized: "Read \(StyledText.slot(0))"), file), nil)
            }
        case .search:
            let pattern = StyledText(input["pattern"]?.stringValue ?? input["query"]?.stringValue ?? "", style: .code)
            let place = input["path"]?.stringValue.map { String(localized: "in \(abbreviated($0))") }
            return (
                standalone
                    ? StyledText(localized: String(localized: "Searched for \(StyledText.slot(0))"), pattern) : pattern,
                place
            )
        case .web:
            if let query = input["query"]?.stringValue {
                let quoted = StyledText(String(localized: "“\(query)”"))
                return (
                    standalone
                        ? StyledText(localized: String(localized: "Searched the web for \(StyledText.slot(0))"), quoted)
                        : quoted, nil
                )
            }
            let url = URL(string: input["url"]?.stringValue ?? "")
            let host = StyledText(url?.host ?? input["url"]?.stringValue ?? "", style: .noun(opens: nil))
            let path = url.map(\.path).flatMap { $0.isEmpty || $0 == "/" ? nil : $0 }
            return (
                standalone ? StyledText(localized: String(localized: "Fetched \(StyledText.slot(0))"), host) : host,
                path
            )
        case .agent:
            let description = input["description"]?.stringValue ?? String(localized: "Agent")
            return (StyledText(description), input["subagent_type"]?.stringValue)
        case .tasks:
            let subject = input["subject"]?.stringValue
            return (StyledText(String(localized: "Updated the task list")), subject)
        case .schedule, .message, .other:
            let name = Self.toolName(call.use.name)
            return (StyledText(name.tool), name.tool == name.server ? nil : name.server)
        }
    }

    /// What a live call says it is doing (01-run.md "Live labels").
    func liveLabel(_ call: ToolCall) -> StyledText {
        let input = call.use.input
        let file = StyledText(Self.fileName(call.filePath ?? ""), style: .noun(opens: nil))
        switch call.kind {
        case .command:
            if let description = input["description"]?.stringValue, !description.isEmpty {
                return StyledText(description)
            }
            return StyledText(Self.firstLine(input["command"]?.stringValue ?? ""), style: .code)
        case .change: return StyledText(localized: String(localized: "Editing \(StyledText.slot(0))"), file)
        case .create: return StyledText(localized: String(localized: "Writing \(StyledText.slot(0))"), file)
        case .read: return StyledText(localized: String(localized: "Reading \(StyledText.slot(0))"), file)
        case .search:
            return StyledText(
                localized: String(localized: "Searching for \(StyledText.slot(0))"),
                StyledText(input["pattern"]?.stringValue ?? "", style: .code))
        case .web:
            if let query = input["query"]?.stringValue {
                return StyledText(String(localized: "Searching the web for “\(query)”"))
            }
            let host = URL(string: input["url"]?.stringValue ?? "")?.host ?? ""
            return StyledText(
                localized: String(localized: "Fetching \(StyledText.slot(0))"),
                StyledText(host, style: .noun(opens: nil)))
        case .agent, .tasks, .schedule, .message, .other:
            return label(call, standalone: true, opens: call.id).0
        }
    }

    /// An item's trailing meta: how it ended when that isn't plainly, else
    /// the one number that says how much.
    private func itemMeta(_ calls: [ToolCall]) -> StyledText {
        let call = calls[calls.count - 1]
        switch call.state {
        case .failed: return StyledText(String(localized: "Failed"), style: .failure)
        case .denied: return StyledText(String(localized: "Denied"))
        case .interrupted: return StyledText(String(localized: "Interrupted"))
        case .waiting: return StyledText(String(localized: "Needs approval"))
        case .background: return StyledText(String(localized: "Background"))
        case .running, .preparing: return StyledText()
        case .done: break
        }
        if call.ranInBackground, let duration = call.duration {
            return StyledText(String(localized: "Background · \(Self.format(duration))"))
        }
        switch call.kind {
        case .change:
            let stats = calls.compactMap(Self.diffStat)
            guard !stats.isEmpty else { return StyledText() }
            return Self.stat(added: stats.map(\.added).reduce(0, +), removed: stats.map(\.removed).reduce(0, +))
        case .create:
            let lines = Self.lineCount(call.use.input["content"]?.stringValue ?? "")
            return StyledText(String(localized: "New · \(lines) lines"))
        case .read:
            switch call.result?.toolOutcome(Tools.Read.self) {
            case .success(.text(let file))?:
                let end = file.startLine + max(file.numLines, 1) - 1
                return StyledText(String(localized: "lines \(file.startLine)–\(end)"))
            case .success(.image)?: return StyledText(String(localized: "Image"))
            case .success(.pdf)?: return StyledText(String(localized: "PDF"))
            case .success(.unchanged)?: return StyledText(String(localized: "Unchanged"))
            default: return StyledText()
            }
        case .search:
            if case .success(let output)? = call.result?.toolOutcome(Tools.Grep.self), Tools.Grep.matches(call.use.name)
            {
                return StyledText(
                    output.numFiles == 1 ? String(localized: "1 file") : String(localized: "\(output.numFiles) files"))
            }
            if case .success(let output)? = call.result?.toolOutcome(Tools.Glob.self), Tools.Glob.matches(call.use.name)
            {
                return StyledText(
                    output.numFiles == 1 ? String(localized: "1 file") : String(localized: "\(output.numFiles) files"))
            }
            return StyledText()
        case .web:
            if case .success(let output)? = call.result?.toolOutcome(Tools.WebFetch.self),
                Tools.WebFetch.matches(call.use.name)
            {
                return StyledText("\(output.code)")
            }
            if case .success(let output)? = call.result?.toolOutcome(Tools.WebSearch.self),
                Tools.WebSearch.matches(call.use.name)
            {
                return StyledText(String(localized: "\(output.links.count) results"))
            }
            return StyledText()
        case .agent:
            if case .success(.completed(let done))? = call.result?.toolOutcome(Tools.Agent.self) {
                return StyledText(
                    String(
                        localized:
                            "\(done.totalToolUseCount) tools · \(Self.format(TimeInterval(done.totalDurationMS) / 1000))"
                    ))
            }
            return StyledText()
        case .command, .tasks, .schedule, .message, .other:
            if let duration = call.duration, duration >= CorpusThresholds.shownDuration {
                return StyledText(Self.format(duration))
            }
            return StyledText()
        }
    }

    // MARK: - News

    /// One background task's news: the CLI's own summary, and what its usage
    /// says (04-background.md "The row").
    func line(for report: TaskReport, kind: TaskNews.Kind, duration: TimeInterval?) -> WorkLine {
        let failed =
            report.status.map { status -> Bool in
                switch status {
                case .failed, .killed: true
                default: false
                }
            } ?? false
        let glyph: Tile.Glyph =
            switch kind {
            case .command: .tool(.command)
            case .agent: .tool(.agent)
            case .workflow: .workflow
            case .monitor: .monitor
            case .other: .tool(.other)
            }
        var meta = StyledText()
        if let usage = report.usage, let agents = usage.agentCount {
            meta = StyledText(String(localized: "\(usage.agentsDone ?? 0) of \(agents) agents"))
            if let failedAgents = usage.agentsFailed, failedAgents > 0 {
                meta.append(StyledText(" · "))
                meta.append(StyledText(String(localized: "\(failedAgents) failed"), style: .failure))
            }
        } else if let usage = report.usage, let tools = usage.totalToolUseCount {
            let time = usage.totalDurationMS.map { Self.format(TimeInterval($0) / 1000) }
            meta = StyledText(
                time.map { String(localized: "\(tools) tools · \($0)") } ?? String(localized: "\(tools) tools"))
        } else if let duration {
            meta = StyledText(Self.format(duration))
        }
        return WorkLine(
            tile: Tile(glyph: glyph, state: failed ? .failed : .done), text: StyledText(report.summary), detail: nil,
            exceptions: StyledText(), meta: meta)
    }

    /// Consecutive news as one row: how many, and how many failed.
    func line(for news: [TaskNews]) -> WorkLine {
        if news.count == 1 { return news[0].line }
        let failed = news.filter { $0.line.tile.state == .failed }.count
        var exceptions = StyledText()
        if failed > 0 {
            exceptions = StyledText("· ") + StyledText(String(localized: "\(failed) failed"), style: .failure)
        }
        return WorkLine(
            tile: news[news.count - 1].line.tile,
            text: StyledText(String(localized: "\(news.count) background tasks finished")), detail: nil,
            exceptions: exceptions, meta: StyledText())
    }

    // MARK: - Pieces

    static func tileState(_ state: ToolCallState) -> Tile.State {
        switch state {
        case .preparing: .preparing
        case .waiting: .waiting
        case .running: .running
        case .background: .background
        case .done: .done
        case .failed: .failed
        case .denied, .interrupted: .stopped
        }
    }

    /// `+12 −3`, green and red.
    private static func stat(added: Int, removed: Int) -> StyledText {
        StyledText("+\(added)", style: .added) + StyledText(" ") + StyledText("−\(removed)", style: .removed)
    }

    /// Lines added and removed by one change or creation.
    static func diffStat(_ call: ToolCall) -> (added: Int, removed: Int)? {
        let hunks: [DiffHunk]?
        switch call.use.name {
        case Tools.Edit.name:
            if case .success(let output)? = call.result?.toolOutcome(Tools.Edit.self) {
                hunks = output.structuredPatch
            } else if let input = call.use.input(as: Tools.Edit.self) {
                return (Self.lineCount(input.newString), Self.lineCount(input.oldString))
            } else {
                hunks = nil
            }
        case Tools.Write.name:
            if case .success(let output)? = call.result?.toolOutcome(Tools.Write.self), !output.isNewFile {
                hunks = output.structuredPatch
            } else {
                return (Self.lineCount(call.use.input["content"]?.stringValue ?? ""), 0)
            }
        default:
            hunks = nil
        }
        guard let hunks, !hunks.isEmpty else { return nil }
        let lines = hunks.flatMap(\.lines)
        return (lines.filter { $0.hasPrefix("+") }.count, lines.filter { $0.hasPrefix("-") }.count)
    }

    /// `34s`, `1m 5s`, `12m`, `1h 3m` — the resolution a reader wants at each
    /// size, in the app's language (not the system's, which the rest of the
    /// line may not be in).
    static func format(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        formatter.calendar = calendar
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        switch seconds {
        case ..<60: formatter.allowedUnits = [.second]
        case ..<600: formatter.allowedUnits = [.minute, .second]
        case ..<3600: formatter.allowedUnits = [.minute]
        default: formatter.allowedUnits = [.hour, .minute]
        }
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds)s"
    }

    static func fileName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// A file's folder, abbreviated.
    func folder(_ path: String) -> String {
        abbreviated((path as NSString).deletingLastPathComponent)
    }

    /// A path relative to the working directory when it is under it, its
    /// middle elided past three components.
    func abbreviated(_ path: String) -> String {
        var path = path
        if let root = workingDirectory, !root.isEmpty {
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if path == root { return "." }
            if path.hasPrefix(prefix) { path.removeFirst(prefix.count) }
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 3 else { return path }
        return "\(parts[0])/\(parts[1])/…/\(parts[parts.count - 1])"
    }

    static func firstLine(_ text: String) -> String {
        let trimmed = text.drop { $0.isNewline }
        return String(trimmed.prefix { !$0.isNewline })
    }

    /// A leading `cd <dir> &&` is how the agent says where, not what.
    static func strippingDirectoryChange(_ command: String) -> String {
        guard command.hasPrefix("cd "), let range = command.range(of: " && ") else { return command }
        let directory = command[command.index(command.startIndex, offsetBy: 3)..<range.lowerBound]
        guard !directory.contains(where: \.isWhitespace) || directory.hasPrefix("\"") else { return command }
        return String(command[range.upperBound...])
    }

    private static func lineCount(_ text: String) -> Int {
        text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// An MCP tool's server and tool (`mcp__computer-use__screenshot`);
    /// any other tool is its own server.
    static func toolName(_ name: String) -> (server: String, tool: String) {
        let parts = name.components(separatedBy: "__")
        if parts.count >= 3, parts[0] == "mcp" { return (parts[1], parts[2...].joined(separator: "__")) }
        return (name, name)
    }

    private static func lowercasingFirst(_ text: StyledText) -> StyledText {
        guard let first = text.runs.first, first.style == .plain, let character = first.text.first,
            character.isUppercase, !(first.text.dropFirst().first?.isUppercase ?? false)
        else { return text }
        var result = StyledText(first.text.prefix(1).lowercased() + first.text.dropFirst())
        for run in text.runs.dropFirst() { result.append(StyledText(run.text, style: run.style)) }
        return result
    }
}
