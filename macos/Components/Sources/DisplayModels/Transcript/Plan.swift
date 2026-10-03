import Foundation

/// An `ExitPlanMode` call: a plan put to the reader for approval
/// (design/transcript/07-talk.md). A caption, then the plan itself as a
/// markdown row, whole — it breaks out of the run around it.
public nonisolated struct Plan: Sendable, Equatable, Identifiable {
    /// The call's id: what a decision answers.
    public let id: String
    /// The plan, as markdown.
    public let text: String
    /// Waiting for the reader's approval: the caption says so and the
    /// decision buttons stand under the plan.
    public let isWaiting: Bool
    /// The caption over the plan: its tile, coral while it waits, and
    /// *Plan · Waiting for your approval* / *Plan*.
    public let caption: Caption

    public init(id: String, text: String, isWaiting: Bool, caption: Caption) {
        self.id = id
        self.text = text
        self.isWaiting = isWaiting
        self.caption = caption
    }
}
