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
// result envelope. So the receive path keeps each call's input by
// `tool_use_id`, then pairs it with its `tool_result` to materialize /
// patch the `TodoEntry`.
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

    /// `TaskCreate` / `TaskUpdate` inputs keyed by tool_use id, captured when
    /// the assistant makes the call and consumed by its result — the result
    /// echoes only the task id (and subject), not the description or
    /// activeForm. Entries are removed once consumed, so the dicts stay small.
    @ObservationIgnored private var pendingCreates: [String: Tools.TaskCreate.Input] = [:]
    @ObservationIgnored private var pendingUpdates: [String: Tools.TaskUpdate.Input] = [:]

    /// @MainActor class deinit would otherwise route through
    /// `swift_task_deinitOnExecutorImpl`, hitting a macOS 26 SDK bug in
    /// libswift_Concurrency. nonisolated deinit skips the executor-hop
    /// path and avoids the bug (mirrors `SessionRuntime`).
    nonisolated deinit {}

    // MARK: - Assistant tool_use → pending input

    /// Remember the input of every `TaskCreate` / `TaskUpdate` call in an
    /// assistant message until its result lands.
    func captureTodoToolUses(in assistant: AssistantMessage) {
        for block in assistant.content {
            guard case .toolUse(let call) = block else { continue }
            if let create = call.input(as: Tools.TaskCreate.self) {
                pendingCreates[call.id] = create
            } else if let update = call.input(as: Tools.TaskUpdate.self) {
                pendingUpdates[call.id] = update
            }
        }
    }

    // MARK: - User tool_result → list

    /// Fold the results of captured `TaskCreate` / `TaskUpdate` calls into
    /// `todos`. No transcript change is needed — the tool_result itself lands
    /// in the timeline through the normal dispatch path.
    func applyTodoToolResult(_ user: UserMessage) {
        for (toolUseID, result) in user.toolResultMessages {
            if let input = pendingCreates.removeValue(forKey: toolUseID),
                case .success(let created)? = result.toolOutcome(Tools.TaskCreate.self)
            {
                let now = Date()
                upsert(
                    TodoEntry(
                        id: created.taskID,
                        subject: created.subject.isEmpty ? input.subject : created.subject,
                        description: input.description.isEmpty ? nil : input.description,
                        activeForm: input.activeForm,
                        status: .pending,
                        createdAt: now,
                        updatedAt: now))
            } else if let input = pendingUpdates.removeValue(forKey: toolUseID),
                case .success(let updated)? = result.toolOutcome(Tools.TaskUpdate.self)
            {
                applyUpdate(input, result: updated)
            }
        }
    }

    private func applyUpdate(_ input: Tools.TaskUpdate.Input, result: Tools.TaskUpdate.Output) {
        guard result.success, let idx = todos.firstIndex(where: { $0.id == input.taskID }) else { return }
        var entry = todos[idx]
        if let status = result.newStatus.flatMap({ TodoEntry.Status(rawValue: $0.rawValue) }) {
            entry.status = status
        }
        if let activeForm = input.activeForm, !activeForm.isEmpty {
            entry.activeForm = activeForm
        }
        if let description = input.description, !description.isEmpty {
            entry.description = description
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
}
