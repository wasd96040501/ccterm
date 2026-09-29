import AgentSDK
import Foundation

/// An `AskUserQuestion` call: questions put to the reader, and the answers
/// given — kept together, like a form filled in
/// (design/transcript/07-talk.md). It breaks out of the run around it.
nonisolated struct Question: Sendable, Equatable, Identifiable {
    let call: ToolCall
    let questions: [Tools.AskUserQuestion.Question]
    /// The chosen option labels by question text; empty until answered.
    let answers: [String: String]

    var id: String { call.id }
}
