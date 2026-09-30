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

    /// The caption over the plan: its tile, coral while it waits, and
    /// *Plan · Waiting for your approval* / *Plan*.
    var caption: Caption {
        Caption(
            glyph: .tile(Tile(glyph: .plan, state: isWaiting ? .waiting : .done)),
            text: isWaiting
                ? String(localized: "Plan · Waiting for your approval")
                // Its own key: "Plan" alone is Settings' subscription plan, which
                // translates differently.
                : String(localized: "Plan (proposed)", defaultValue: "Plan"))
    }
}
