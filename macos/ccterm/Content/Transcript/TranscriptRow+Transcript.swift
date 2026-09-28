import AgentSDK
import Foundation
import TranscriptKit

nonisolated extension TranscriptRow {
    /// The rows a read-only transcript shows: what the user typed — prompts,
    /// and commands run in the CLI with what they printed — what other
    /// agents sent in, one line per background task's news and per
    /// interruption, what the model wrote, one line per tool call, and a rule
    /// where the conversation was compacted. Thinking, tool results and text
    /// the CLI added for the model are left out — they are the working, not
    /// the conversation.
    static func rows(for transcript: Transcript) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        for (index, message) in transcript.messages.enumerated() {
            switch message {
            case .user(let user):
                if let content = content(for: user) { rows.append(TranscriptRow(id: "\(index)", content: content)) }
            case .assistant(let assistant):
                for (part, block) in assistant.content.enumerated() {
                    let id = "\(index).\(part)"
                    switch block {
                    case .text(let text) where !text.isEmpty:
                        rows.append(TranscriptRow(id: id, content: .markdown(text)))
                    case .toolUse(let call):
                        rows.append(TranscriptRow(id: id, content: .markdown(markdown(for: call))))
                    default:
                        break
                    }
                }
            case .system(.compactBoundary):
                let note = String(localized: "Conversation compacted")
                rows.append(TranscriptRow(id: "\(index)", content: .markdown("---\n\n*\(note)*")))
            default:
                break
            }
        }
        return rows
    }

    /// How a user message reads, or `nil` for one the transcript leaves out.
    private static func content(for user: UserMessage) -> TranscriptRowContent? {
        switch user.kind {
        case .prompt:
            let text = user.content.compactMap(\.text).joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : .userMessage(text)
        case .slashCommand(let name, let arguments):
            return .userMessage(arguments.isEmpty ? name : "\(name) \(arguments)")
        case .shellCommand(let command):
            return .userMessage("!\(command)")
        case .commandOutput(let standardOutput, let standardError):
            let output = [standardOutput, standardError].filter { !$0.isEmpty }.joined(separator: "\n")
            return output.isEmpty ? nil : .markdown(output)
        case .taskNotification(let notification):
            return .markdown("*\(notification.summary)*")
        case .message(let sender, let text):
            return .markdown("**\(title(of: sender))**\n\n\(text)")
        case .interruption:
            return .markdown("*\(String(localized: "Interrupted"))*")
        case .toolResult, .compactionSummary, .synthetic:
            return nil
        }
    }

    private static func title(of sender: UserMessage.Sender) -> String {
        switch sender {
        case .agent(let id): String(localized: "Report from subagent \(id)")
        case .session(let address, let name, _): String(localized: "Message from session \(name ?? address)")
        case .coordinator: String(localized: "Message from the coordinator")
        case .plugin(let name): String(localized: "Message from the \(name) plugin")
        }
    }

    /// `**Bash** `git status`` — the tool, and the one argument that says
    /// what it was doing.
    private static func markdown(for call: ToolUseBlock) -> String {
        let keys = ["command", "file_path", "notebook_path", "pattern", "url", "query", "description", "prompt"]
        guard let argument = keys.lazy.compactMap({ call.input[$0]?.stringValue }).first else {
            return "**\(call.name)**"
        }
        let firstLine = argument.drop(while: \.isNewline).prefix { !$0.isNewline }
        let line = firstLine.count > 160 ? firstLine.prefix(160) + "…" : String(firstLine)
        return "**\(call.name)** `\(line.replacingOccurrences(of: "`", with: "'"))`"
    }
}
