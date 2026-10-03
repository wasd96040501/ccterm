import DisplayModels
import Foundation

nonisolated extension Plan {
    /// The plan of the `ExitPlanMode` call `call`, worded: the page keeps the
    /// call beside it (`TranscriptEntry.plan`).
    init(call: ToolCall, text: String) {
        let isWaiting: Bool
        if case .waiting = call.state { isWaiting = true } else { isWaiting = false }
        self.init(
            id: call.id, text: text, isWaiting: isWaiting,
            caption: Caption(
                glyph: .tile(Tile(glyph: .plan, state: isWaiting ? .waiting : .done)),
                text: isWaiting
                    ? String(localized: "Plan · Waiting for your approval")
                    // Its own key: "Plan" alone is Settings' subscription plan, which
                    // translates differently.
                    : String(localized: "Plan (proposed)", defaultValue: "Plan")))
    }
}
