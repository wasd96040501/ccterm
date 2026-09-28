import AgentSDK
import Foundation
import TranscriptKit

/// A transcript as a read-only tab shows it: the rows, and for each row the
/// app draws itself (`.view`), the card behind it.
///
/// What shows: what the user typed, and commands run in the CLI with what they
/// printed; what other agents sent in; what the model wrote; each stretch of
/// tool calls with nothing said between them as one card; background tasks'
/// news, interruptions and compactions as a line each. Thinking, and text the
/// CLI added for the model, are left out — they are the working, not the
/// conversation.
nonisolated struct TranscriptOutline: Sendable {
    var rows: [TranscriptRow] = []
    var cards: [TranscriptRow.ID: TranscriptCard] = [:]

    init(rows: [TranscriptRow], cards: [TranscriptRow.ID: TranscriptCard] = [:]) {
        self.rows = rows
        self.cards = cards
    }

    /// `source` is the file `transcript` was read from — what the documents it
    /// opens are known by.
    init(_ transcript: Transcript, source: URL) {
        var builder = Builder(messages: transcript.messages, source: source)
        builder.build()
        rows = builder.rows
        cards = builder.cards
    }
}

private nonisolated struct Builder {
    let messages: [Message]
    let source: URL
    var rows: [TranscriptRow] = []
    var cards: [TranscriptRow.ID: TranscriptCard] = [:]

    /// The message answering each tool call, by call id.
    private var results: [String: UserMessage] = [:]
    private var context: ToolStep.Context
    /// The group being gathered and the id its row will have.
    private var pending: (id: String, steps: [ToolStep])?
    /// Output messages already folded into the command before them.
    private var consumed = Set<Int>()

    init(messages: [Message], source: URL) {
        self.messages = messages
        self.source = source
        context = ToolStep.Context(source: source)
        for case .user(let user) in messages {
            if let result = user.toolResult { results[result.toolUseID] = user }
        }
    }

    mutating func build() {
        for (index, message) in messages.enumerated() {
            switch message {
            case .user(let user):
                add(user, at: index)
            case .assistant(let assistant):
                for (part, block) in assistant.content.enumerated() {
                    switch block {
                    case .text(let text) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                        append("\(index).\(part)", .markdown(text))
                    case .toolUse(let call):
                        gather(call, id: "\(index).\(part)")
                    default:
                        break
                    }
                }
            case .system(.compactBoundary):
                append("\(index)", card: .notice(.compaction))
            default:
                break
            }
        }
        flush()
    }

    private mutating func add(_ user: UserMessage, at index: Int) {
        switch user.kind {
        case .prompt:
            let text = user.content.compactMap(\.text).joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { append("\(index)", .userMessage(text)) }
        case .slashCommand(let name, let arguments):
            command(.slash, input: arguments.isEmpty ? name : "\(name) \(arguments)", at: index)
        case .shellCommand(let command):
            self.command(.shell, input: command, at: index)
        case .commandOutput(let output, let errorOutput):
            guard !consumed.contains(index), !(output.isEmpty && errorOutput.isEmpty) else { return }
            let card = LocalCommand(
                kind: nil, input: nil, output: output, errorOutput: errorOutput,
                document: commandDocument(key: "\(index)", title: String(localized: "Output"), nil, output, errorOutput)
            )
            append("\(index)", card: .command(card))
        case .taskNotification(let notification):
            let id = ToolDocument.ID(transcript: source, key: "notification.\(index)")
            append("\(index)", card: .notice(TranscriptNotice(notification, id: id)))
        case .message(let sender, let text):
            append("\(index)", .markdown("**\(Self.title(of: sender))**\n\n\(text)"))
        case .interruption:
            append("\(index)", card: .notice(.interruption))
        case .toolResult, .compactionSummary, .synthetic:
            // Between a call and the next, not a break in the stretch.
            break
        }
    }

    // MARK: - Tool calls

    private mutating func gather(_ call: ToolUseBlock, id: String) {
        let step = ToolStep(call: call, result: results[call.id], context: context)
        if let bash = call.input(as: Tools.Bash.self),
            case .success(let output)? = results[call.id]?.toolOutcome(Tools.Bash.self),
            let taskID = output.backgroundTaskID
        {
            context.backgroundCommands[taskID] = bash
        }
        if pending == nil { pending = (id, []) }
        pending?.steps.append(step)
    }

    private mutating func flush() {
        guard let group = pending else { return }
        pending = nil
        let id = TranscriptRow.ID(group.id)
        rows.append(TranscriptRow(id: id, content: .view))
        cards[id] = .tools(ToolGroup(steps: group.steps))
    }

    // MARK: - Local commands

    /// A command and, when the message after it is its output, that output —
    /// skipping the notes the CLI files between them.
    private mutating func command(_ kind: LocalCommand.Kind, input: String, at index: Int) {
        var output = ""
        var errorOutput = ""
        var next = index + 1
        while next < messages.count, case .user(let user) = messages[next] {
            if case .commandOutput(let out, let err) = user.kind {
                output = out
                errorOutput = err
                consumed.insert(next)
                break
            }
            guard user.kind == .synthetic else { break }
            next += 1
        }
        let title = kind == .slash ? input.components(separatedBy: " ").first ?? input : input
        let document =
            output.isEmpty && errorOutput.isEmpty
            ? nil : commandDocument(key: "\(index)", title: title, input, output, errorOutput)
        let card = LocalCommand(kind: kind, input: input, output: output, errorOutput: errorOutput, document: document)
        append("\(index)", card: .command(card))
    }

    private func commandDocument(
        key: String, title: String, _ command: String?, _ output: String, _ errorOutput: String
    ) -> ToolDocument {
        ToolDocument(
            id: ToolDocument.ID(transcript: source, key: "command.\(key)"), title: title, symbol: "apple.terminal",
            content: .command(
                .init(command: command, description: nil, output: output, errorOutput: errorOutput, status: .unknown)))
    }

    // MARK: - Rows

    private mutating func append(_ id: String, _ content: TranscriptRowContent) {
        flush()
        rows.append(TranscriptRow(id: id, content: content))
    }

    private mutating func append(_ id: String, card: TranscriptCard) {
        flush()
        let rowID = TranscriptRow.ID(id)
        rows.append(TranscriptRow(id: rowID, content: .view))
        cards[rowID] = card
    }

    private static func title(of sender: UserMessage.Sender) -> String {
        switch sender {
        case .agent(let id): String(localized: "Report from subagent \(id)")
        case .session(let address, let name, _): String(localized: "Message from session \(name ?? address)")
        case .coordinator: String(localized: "Message from the coordinator")
        case .plugin(let name): String(localized: "Message from the \(name) plugin")
        }
    }
}
