import AgentSDK
import Foundation

/// The header of a document set as markdown — a search, a page fetched, an
/// agent, the task list, a task's news, a command's output, a compaction's
/// summary, anything else.
///
/// The title is the crumb and the tab's name: a search is *Search: pattern*
/// and counts its files at the bar's end; an agent is its description; news
/// is the task's own name; any other call is its tool. The tile is the
/// kind's, in the call's state, so a document waiting for the reader shows
/// the coral outline (design/transcript/preview.js `markdownDoc`,
/// `searchDoc`, `agentDoc`).
nonisolated extension DocumentHeader {
    static func markdown(_ content: DocumentContent) -> DocumentHeader {
        switch content {
        case .search(let call):
            let title = String(localized: "Search: \(searchTerm(call))")
            return DocumentHeader(
                tile: Tile(glyph: .tool(.search), state: Tile.State(call.state)), crumbs: [title],
                stat: StyledText(fileCount(call) ?? ""),
                title: title)
        case .web(let call):
            let title = webTitle(call)
            return DocumentHeader(
                tile: Tile(glyph: .tool(.web), state: Tile.State(call.state)), crumbs: [title], title: title)
        case .agent(let call):
            let description = call.use.input["description"]?.stringValue ?? ""
            let title = description.isEmpty ? String(localized: "Agent") : description
            return DocumentHeader(
                tile: Tile(glyph: .tool(.agent), state: Tile.State(call.state)), crumbs: [title], title: title)
        case .agentMessage(let message):
            return DocumentHeader(
                tile: message.line.tile, crumbs: [message.name], title: message.name)
        case .taskList:
            let title = String(localized: "Task list")
            return DocumentHeader(tile: Tile(glyph: .tool(.tasks), state: .done), crumbs: [title], title: title)
        case .news(let news):
            let title = newsTitle(news)
            return DocumentHeader(
                tile: Tile(glyph: news.line.tile.glyph, state: news.line.tile.state), crumbs: [title], title: title)
        case .commandOutput(let command):
            let title = command.title
            return DocumentHeader(tile: Tile(glyph: .tool(.command), state: .done), crumbs: [title], title: title)
        case .log(let failure):
            let title = String(localized: "Session Log")
            return DocumentHeader(
                tile: Tile(glyph: .tool(.command), state: .failed), crumbs: [title], stat: StyledText(failure.message),
                title: title, showsTranscriptJump: false)
        case .contextUsage(let usage):
            let title = String(localized: "Context Usage")
            let percent = usage.percentage
            return DocumentHeader(
                tile: Tile(glyph: .tool(.command), state: .done), crumbs: [title],
                stat: StyledText("\(percent)%"), title: title, showsTranscriptJump: false)
        case .compactionSummary:
            let title = String(localized: "Summary")
            return DocumentHeader(tile: Tile(glyph: .tool(.other), state: .done), crumbs: [title], title: title)
        case .advice(let call):
            let title = String(localized: "Advisor")
            return DocumentHeader(
                tile: Tile(glyph: .tool(.advisor), state: Tile.State(call.state)), crumbs: [title], title: title)
        case .sentMessage(let call):
            let title = String(localized: "To \(call.sentMessage?.party ?? "")")
            return DocumentHeader(
                tile: Tile(glyph: .tool(.message), state: Tile.State(call.state)), crumbs: [title], title: title)
        case .continuationPrompt:
            let title = String(localized: "Prompt")
            return DocumentHeader(tile: Tile(glyph: .tool(.other), state: .done), crumbs: [title], title: title)
        case .image(let image):
            return DocumentHeader(
                tile: Tile(glyph: .image, state: .done), crumbs: [image.title],
                stat: StyledText("\(image.dimensions) · \(image.format)"), title: image.title)
        case .other(let call):
            let title = call.toolName.tool
            return DocumentHeader(
                tile: Tile(glyph: .tool(call.kind), state: Tile.State(call.state)), crumbs: [title], title: title)
        case .command(let call):
            return .command(call)
        case .shellCommand(let command):
            return .shellCommand(command)
        case .change, .newFile, .read:
            return .source(content, workingDirectory: nil)
        }
    }

    /// What was searched for: a pattern, or a tool search's query.
    static func searchTerm(_ call: ToolCall) -> String {
        call.use.input["pattern"]?.stringValue ?? call.use.input["query"]?.stringValue ?? ""
    }

    /// *12 files*, when the result says.
    private static func fileCount(_ call: ToolCall) -> String? {
        let count: Int?
        switch call.result?.toolOutcome(Tools.Grep.self) {
        case .success(let output)? where Tools.Grep.matches(call.use.name): count = output.numFiles
        default:
            switch call.result?.toolOutcome(Tools.Glob.self) {
            case .success(let output)? where Tools.Glob.matches(call.use.name): count = output.numFiles
            default: count = nil
            }
        }
        guard let count else { return nil }
        return count == 1 ? String(localized: "1 file") : String(localized: "\(count) files")
    }

    /// A search’s query in quotes; a fetch’s host.
    private static func webTitle(_ call: ToolCall) -> String {
        if let query = call.use.input["query"]?.stringValue { return String(localized: "“\(query)”") }
        let url = call.use.input["url"]?.stringValue ?? ""
        return URL(string: url)?.host ?? url
    }

    /// The task's own name — what the CLI quoted in its summary — else the
    /// whole summary.
    private static func newsTitle(_ news: TaskNews) -> String {
        let summary = news.report.summary
        for (open, close) in [("“", "”"), ("\"", "\"")] {
            guard let start = summary.range(of: open),
                let end = summary.range(of: close, range: start.upperBound..<summary.endIndex)
            else { continue }
            let name = summary[start.upperBound..<end.lowerBound]
            if !name.isEmpty { return String(name) }
        }
        return summary
    }
}
