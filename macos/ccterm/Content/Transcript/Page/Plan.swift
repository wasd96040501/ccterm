import Foundation

/// An `ExitPlanMode` call: a plan put to the reader for approval
/// (design/transcript/07-talk.md). A caption, then the plan itself as a
/// markdown row, whole — it breaks out of the run around it.
nonisolated struct Plan: Sendable, Equatable, Identifiable {
    let call: ToolCall
    /// The plan, as markdown.
    let text: String

    var id: String { call.id }

    /// Waiting for the reader's approval: the caption says so and the
    /// decision buttons stand under the plan.
    var isWaiting: Bool {
        if case .waiting = call.state { true } else { false }
    }
}
