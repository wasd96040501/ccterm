import AgentSDK
import Foundation

/// A message another party put into the conversation — a subagent, another
/// session, the coordinator, a plugin (design/transcript/06-voices.md).
/// A caption naming them, then their words as a quoted markdown row.
nonisolated struct Voice: Sendable, Equatable, Identifiable {
    let id: String
    let sender: UserMessage.Sender
    /// Who is speaking, as the caption says it: a subagent's description when
    /// the page knows the call that started it, a session's name, …
    let name: String
    /// What they said, as markdown.
    let text: String
}
