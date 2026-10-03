import AgentSDK
import DisplayModels
import Foundation

nonisolated extension Approval {
    /// `call` is waiting (`ToolCallState.waiting`): the card's words and the
    /// bar's, composed from the call's input.
    init(_ call: ToolCall) {
        let reason: String?
        if case .waiting(let why) = call.state { reason = why } else { reason = nil }
        let input = call.use.input
        let file = (call.filePath as NSString?)?.lastPathComponent ?? ""
        func lines(_ text: String?) -> [String] {
            guard let text, !text.isEmpty else { return [] }
            return text.components(separatedBy: "\n")
        }
        let title: String
        let body: Body?
        let request: String
        switch call.kind {
        case .command:
            title = input["description"]?.stringValue ?? String(localized: "Run a command")
            body = input["command"]?.stringValue.map { .command($0) }
            request = String(localized: "Claude wants to run this command")
        case .change:
            title = String(localized: "Edit \(file)")
            let edits = input["edits"]?.arrayValue ?? [input]
            body = .change(
                removed: edits.flatMap { lines($0["old_string"]?.stringValue) },
                added: edits.flatMap { lines($0["new_string"]?.stringValue ?? $0["new_source"]?.stringValue) })
            request = String(localized: "Claude wants to make this edit")
        case .create:
            title = String(localized: "Create \(file)")
            body = .newFile(lines(input["content"]?.stringValue))
            request = String(localized: "Claude wants to create this file")
        case .agent, .web, .search, .read, .tasks, .schedule, .advisor, .skill, .worktree, .message, .notify, .other:
            title = String(localized: "Use \(call.use.name)")
            body = nil
            request = String(localized: "Claude wants to use \(call.use.name)")
        }
        self.init(
            id: call.id, tile: Tile(glyph: .tool(call.kind), state: .waiting), title: title, body: body,
            reason: reason, request: request)
    }
}
