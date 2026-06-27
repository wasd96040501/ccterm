import AgentSDK
import Foundation
import Observation

// MARK: - Todo merger
//
// The current CLI's todo plan surfaces through two tools:
//
//   - `TaskCreate` — `input.subject` + `description?` + `activeForm?`.
//     The tool_result echoes back `task.id` + `task.subject`.
//   - `TaskUpdate` — `input.taskId` + any of `status` / `description` /
//     `activeForm` / `owner` / `addBlockedBy`. The tool_result echoes
//     `taskId` + `statusChange.from/.to` + `updatedFields`.
//
// We rebuild the structured list off these two flows. The tool_use
// alone isn't enough — `TaskCreate`'s assigned id only appears in the
// result envelope. So the receive path captures the tool_use input
// into a scratch dict keyed by `tool_use_id`, then pairs it with the
// matching `tool_result` to materialize / patch the `TodoEntry`.
//
// `TaskList` / `TaskGet` are read-only on the agent's side; they do
// not mutate the plan and are intentionally ignored here.

/// The assistant's live todo plan, projected off the CLI's
/// `TaskCreate` / `TaskUpdate` tool-call stream.
///
/// This is a **reference-type `@Observable` projection** owned by
/// `SessionRuntime` (`runtime.todoTracker`). It must stay a class:
/// `todos` is mutated **in place** (`todos[idx] = ...`) and SwiftUI
/// readers observe the live array through the nested chain
/// `session.todos` → `runtime.todoTracker.todos`. Making it a value
/// type would copy the array on every read and break live
/// re-rendering of the todo popover.
@Observable
@MainActor
final class TodoTracker {

    /// The assistant's live todo plan. Built from the CLI's `TaskCreate`
    /// / `TaskUpdate` tool calls. The matching tool_use / tool_result
    /// blocks remain visible in the transcript; this collection is a
    /// structured off-band projection so the input-bar popover can render
    /// the plan without re-parsing the timeline.
    var todos: [TodoEntry] = []

    /// Internal scratch — `TaskCreate` input keyed by `tool_use_id`,
    /// captured the moment the assistant emits the tool_use so we can
    /// pair it with the subsequent tool_result (which only echoes
    /// `task.id` + `subject`, dropping the description / activeForm).
    /// Entries are removed once consumed; the dict stays small even on
    /// long sessions.
    @ObservationIgnored private var pendingTodoCreates: [String: TodoEntry.CreateScratch] = [:]
    @ObservationIgnored private var pendingTodoUpdates: [String: TodoEntry.UpdateScratch] = [:]

    /// @MainActor class deinit would otherwise route through
    /// `swift_task_deinitOnExecutorImpl`, hitting a macOS 26 SDK bug in
    /// libswift_Concurrency. nonisolated deinit skips the executor-hop
    /// path and avoids the bug (mirrors `SessionRuntime`).
    nonisolated deinit {}

    // MARK: - Assistant tool_use → scratch

    /// Walk an assistant message's content blocks; for every
    /// `TaskCreate` / `TaskUpdate` tool_use, snapshot the input into
    /// the matching scratch dict. The pairing tool_result will consume
    /// the entry. Called from `receive` regardless of `mode`, so
    /// JSONL replay rebuilds the same `todos` list.
    func captureTodoToolUses(in assistant: Message2Assistant) {
        guard let blocks = assistant.message?.content else { return }
        let now = Date()
        for block in blocks {
            guard case .toolUse(let tu) = block else { continue }
            switch tu {
            case .TaskCreate(let create):
                guard let id = create.id else { continue }
                pendingTodoCreates[id] = TodoEntry.CreateScratch(
                    subject: create.input?.subject,
                    description: create.input?.description,
                    activeForm: create.input?.activeForm,
                    capturedAt: now
                )
            case .TaskUpdate(let update):
                guard let id = update.id else { continue }
                pendingTodoUpdates[id] = TodoEntry.UpdateScratch(
                    taskId: update.input?.taskId,
                    status: update.input?.status,
                    description: update.input?.description,
                    activeForm: update.input?.activeForm,
                    capturedAt: now
                )
            default:
                continue
            }
        }
    }

    // MARK: - User tool_result → list

    /// Inspect the user message's tool_result envelope. If it pairs
    /// with a previously-captured `TaskCreate` / `TaskUpdate`, fold
    /// the data into `todos`. Returns nothing — caller doesn't need to
    /// emit a transcript change for the popover update (the matching
    /// tool_result already lands in the timeline through the normal
    /// dispatch path).
    func applyTodoToolResult(_ user: Message2User) {
        guard case .object(let obj) = user.toolUseResult else { return }
        switch obj {
        case .TaskCreate(let result, _):
            applyTaskCreateResult(result, in: user)
        case .TaskUpdate(let result, _):
            applyTaskUpdateResult(result)
        default:
            return
        }
    }

    private func applyTaskCreateResult(_ result: ObjectTaskCreate, in user: Message2User) {
        guard let task = result.task,
            let taskId = task.id,
            let toolUseId = Self.firstToolUseId(in: user)
        else { return }
        let scratch = pendingTodoCreates.removeValue(forKey: toolUseId)
        // The result echoes `subject` reliably; fall back to scratch
        // when the result somehow misses it.
        let subject = task.subject ?? scratch?.subject ?? ""
        let now = Date()
        let entry = TodoEntry(
            id: taskId,
            subject: subject,
            description: scratch?.description,
            activeForm: scratch?.activeForm,
            status: .pending,
            createdAt: now,
            updatedAt: now
        )
        upsert(entry)
    }

    private func applyTaskUpdateResult(_ result: ObjectTaskUpdate) {
        guard result.success ?? true,
            let taskId = result.taskId,
            let idx = todos.firstIndex(where: { $0.id == taskId })
        else { return }
        var entry = todos[idx]
        if let to = result.statusChange?.to,
            let mapped = TodoEntry.Status(rawValue: to)
        {
            entry.status = mapped
        }
        // Pull the activeForm / description patch out of whatever
        // matching scratch we still have. We scan every scratch with
        // taskId == this id since the assistant can re-update the same
        // task across multiple turns; we want the most recent input.
        if let scratch = consumeMostRecentUpdateScratch(forTaskId: taskId) {
            if let activeForm = scratch.activeForm, !activeForm.isEmpty {
                entry.activeForm = activeForm
            }
            if let description = scratch.description, !description.isEmpty {
                entry.description = description
            }
        }
        entry.updatedAt = Date()
        todos[idx] = entry
    }

    // MARK: - Helpers

    private func upsert(_ todo: TodoEntry) {
        if let idx = todos.firstIndex(where: { $0.id == todo.id }) {
            // Idempotent replay: keep the original createdAt; the new
            // entry is the more recent observation for everything else.
            todos[idx] = TodoEntry(
                id: todo.id,
                subject: todo.subject,
                description: todo.description,
                activeForm: todo.activeForm,
                status: todo.status,
                createdAt: todos[idx].createdAt,
                updatedAt: todo.updatedAt
            )
        } else {
            todos.append(todo)
        }
    }

    /// Find the most recently captured `TaskUpdate` scratch for the
    /// given task id, remove it from the pending dict, and return it.
    /// Returns nil when no scratch matches (e.g. a server-initiated
    /// update without an originating tool_use, which the current CLI
    /// doesn't emit but we tolerate).
    private func consumeMostRecentUpdateScratch(forTaskId taskId: String) -> TodoEntry.UpdateScratch? {
        let hits = pendingTodoUpdates.filter { $0.value.taskId == taskId }
        guard let (key, scratch) = hits.max(by: { $0.value.capturedAt < $1.value.capturedAt })
        else { return nil }
        pendingTodoUpdates.removeValue(forKey: key)
        return scratch
    }

    /// The user envelope's tool_result block always carries one
    /// tool_use_id when present; pull it without re-parsing.
    private static func firstToolUseId(in user: Message2User) -> String? {
        guard case .array(let items) = user.message?.content else { return nil }
        for item in items {
            if case .toolResult(let r) = item { return r.toolUseId }
        }
        return nil
    }
}
