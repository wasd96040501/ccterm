import AgentSDK
import Foundation

// The timeline rules both ingest paths share — live `receive` and the
// history `ReverseEntryBuilder` — so the two cannot drift apart
// (`TranscriptReverseBuilderTests` pins their equivalence).

extension UserMessage {
    /// Whether this message enters the timeline as its own entry: something
    /// the user said, with visible text. Subagent traffic, synthetic
    /// CLI-injected messages and background-task notifications stay out.
    var isVisible: Bool {
        guard parentToolUseID == nil, !isSynthetic, origin != "task-notification",
            !startsWithTaskNotificationEnvelope
        else { return false }
        return content.contains { block in
            if case .text(let text) = block { return !text.isEmpty }
            return false
        }
    }

    /// Whether the text starts with the `<task-notification>` envelope — the
    /// CLI's background-task turn trigger, which older CLIs send without
    /// `origin`.
    private var startsWithTaskNotificationEnvelope: Bool {
        for block in content {
            if case .text(let text) = block { return text.hasPrefix("<task-notification>") }
        }
        return false
    }

    /// One message per `tool_result` block, each carrying only that block —
    /// the shape `SingleEntry.toolResults` stores. The structured output is
    /// kept only when it is unambiguous (a single result).
    var toolResultMessages: [(toolUseID: String, message: UserMessage)] {
        let results = content.compactMap { block -> ToolResultBlock? in
            if case .toolResult(let result) = block { return result }
            return nil
        }
        return results.map { result in
            var single = self
            single.content = [.toolResult(result)]
            if results.count > 1 { single.toolUseResult = nil }
            return (result.toolUseID, single)
        }
    }
}

extension AssistantMessage {
    /// Has text or a tool call. Thinking-only and subagent messages don't
    /// enter the timeline.
    var isVisible: Bool {
        guard parentToolUseID == nil else { return false }
        return content.contains { block in
            switch block {
            case .text(let text): return !text.isEmpty
            case .toolUse: return true
            default: return false
            }
        }
    }

    /// The `.text` blocks joined by blank lines; `nil` without text.
    var joinedText: String? {
        let parts = content.compactMap { block -> String? in
            if case .text(let text) = block, !text.isEmpty { return text }
            return nil
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}

extension Message {
    /// An assistant message made only of tool calls. Consecutive ones fold
    /// into one tool group; anything with text renders on its own.
    var isGroupableAssistant: Bool {
        guard case .assistant(let a) = self, !a.content.isEmpty else { return false }
        return a.content.allSatisfy { block in
            if case .toolUse = block { return true }
            return false
        }
    }
}
