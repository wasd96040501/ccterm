import AgentSDK
import Foundation
import TranscriptKit

nonisolated extension TranscriptRow {
    /// The rows a read-only transcript shows: what the user typed — prompts,
    /// and commands run in the CLI with what they printed — what the model
    /// wrote, one line per tool call, and a rule where the conversation
    /// was compacted. Thinking, tool results and messages the CLI injected are
    /// left out — they are the working, not the conversation.
    static func rows(for transcript: Transcript) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        for (index, message) in transcript.messages.enumerated() {
            switch message {
            case .user(let user):
                guard !user.isSynthetic else { continue }
                switch user.localCommand {
                case .input(let command):
                    rows.append(TranscriptRow(id: "\(index)", content: .userMessage(command)))
                    continue
                case .output(let standardOutput, let standardError):
                    let output = [standardOutput, standardError].filter { !$0.isEmpty }.joined(separator: "\n")
                    if !output.isEmpty { rows.append(TranscriptRow(id: "\(index)", content: .markdown(output))) }
                    continue
                case nil:
                    break
                }
                let text = user.content.compactMap(\.text).joined(separator: "\n\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { rows.append(TranscriptRow(id: "\(index)", content: .userMessage(text))) }
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
