import AgentSDK
import Foundation

/// A call stopped on a permission request, worded for the two places that
/// ask the reader: the approval card under its run (01-run.md "Waiting for
/// you") and the approval bar over its document (02-command.md "Live").
/// Answering either answers the call.
nonisolated struct Approval: Sendable, Equatable, Identifiable {
    /// What the call will do, whole: the command, the lines an edit takes out
    /// and puts in, or a new file's lines.
    enum Body: Sendable, Equatable {
        case command(String)
        case change(removed: [String], added: [String])
        case newFile([String])
    }

    /// The call's id — what a decision answers.
    let id: String
    /// The kind's tile, coral.
    let tile: Tile
    /// The card's heading: *Run the unit tests*, *Edit A.swift*.
    let title: String
    let body: Body?
    /// Why the CLI asked, in its words; `nil` when it gave none.
    let reason: String?
    /// The bar's words: *Claude wants to run this command*.
    let request: String

    /// `call` is waiting (`ToolCallState.waiting`).
    init(_ call: ToolCall) {
        id = call.id
        tile = Tile(glyph: .tool(call.kind), state: .waiting)
        if case .waiting(let reason) = call.state { self.reason = reason } else { reason = nil }
        let input = call.use.input
        let file = (call.filePath as NSString?)?.lastPathComponent ?? ""
        func lines(_ text: String?) -> [String] {
            guard let text, !text.isEmpty else { return [] }
            return text.components(separatedBy: "\n")
        }
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
        case .agent, .web, .search, .read, .tasks, .schedule, .message, .other:
            title = String(localized: "Use \(call.use.name)")
            body = nil
            request = String(localized: "Claude wants to use \(call.use.name)")
        }
    }
}
