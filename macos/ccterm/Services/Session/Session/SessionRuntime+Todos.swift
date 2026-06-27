import AgentSDK
import Foundation

// MARK: - Todo scratch types
//
// The merger that consumes these lives on `TodoTracker` (the
// `@Observable` projection owned by `SessionRuntime`). These scratch
// structs stay attached to `TodoEntry` itself — they are captured at
// the moment the assistant emits a `TaskCreate` / `TaskUpdate`
// tool_use and held until the pairing tool_result lands, so the merge
// is atomic per call.

extension TodoEntry {

    /// Captured at the moment the assistant emits a `TaskCreate`
    /// tool_use. The result envelope only echoes `id` + `subject`, so
    /// we have to hold onto `description` / `activeForm` from the
    /// input until the pairing tool_result lands.
    struct CreateScratch {
        let subject: String?
        let description: String?
        let activeForm: String?
        let capturedAt: Date
    }

    /// Captured at the moment the assistant emits a `TaskUpdate`
    /// tool_use. The result envelope carries the new status but the
    /// `activeForm` / `description` patches only live on the input
    /// side. We hold the latest until the matching tool_result lands
    /// so the merge is atomic per call.
    struct UpdateScratch {
        let taskId: String?
        let status: String?
        let description: String?
        let activeForm: String?
        let capturedAt: Date
    }
}
