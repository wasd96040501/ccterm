import AgentSDK
import Foundation
import Observation

// MARK: - Background task signals
//
// The CLI emits four message types around a background bash invocation:
//
//   1. `assistant.tool_use(Bash, run_in_background: true)` — the launch
//   2. `system.task_started` — task accepted, has task_id + tool_use_id
//      + description + task_type
//   3. `user.tool_result` — carries the absolute path of the spool file
//      ("Output is being written to: …") + the backgroundTaskId
//   4. `system.task_updated` — patches status / end time on the entry.
//   5. `system.task_notification` — terminal payload with status,
//      output_file, summary, usage. Triggers a synthetic follow-up turn
//      so the assistant can act on the result.
//
// None of those user-visible messages belong in the transcript: signals
// (2)/(4)/(5) are control-only and are intentionally dropped by the
// dispatch arms in `receive`. The matching tool_use+tool_result pair
// already renders as a tool group in the transcript; the popover
// surfaces long-running state for those tools off-band.

/// Background bash tasks the CLI is tracking for this session,
/// projected off the `system.task_started` / `task_updated` /
/// `task_notification` control stream.
///
/// This is a **reference-type `@Observable` projection** owned by
/// `SessionRuntime` (`runtime.taskTracker`). It must stay a class:
/// `tasks` is mutated **in place** (`tasks[idx] = ...`) and SwiftUI
/// readers observe the live array through the nested chain
/// `session.tasks` → `runtime.taskTracker.tasks`. Making it a value
/// type would copy the array on every read and break live
/// re-rendering of the tasks popover.
///
/// `tasks` is ordered chronologically (oldest first); the popover
/// groups them by running vs. terminal at render time.
@Observable
@MainActor
final class TaskTracker {

    var tasks: [BackgroundTask] = []

    /// @MainActor class deinit would otherwise route through
    /// `swift_task_deinitOnExecutorImpl`, hitting a macOS 26 SDK bug in
    /// libswift_Concurrency. nonisolated deinit skips the executor-hop
    /// path and avoids the bug (mirrors `SessionRuntime`).
    nonisolated deinit {}

    /// `command` is the back-filled shell text the runtime resolves by
    /// scanning its message timeline (`SessionRuntime.bashCommand(forToolUseId:)`)
    /// — the tracker has no access to `messages`, so the caller passes
    /// the already-resolved value in.
    func handleTaskStarted(_ started: SystemMessage.TaskStarted, command: String?) {
        let taskId = started.taskID
        let existingOutputFile = tasks.first(where: { $0.id == taskId })?.outputFile
        let task = BackgroundTask(
            id: taskId,
            toolUseId: started.toolUseID,
            description: started.description,
            taskType: started.taskType,
            command: command,
            outputFile: existingOutputFile,
            startedAt: Date(),
            endedAt: nil,
            status: .running,
            summary: nil
        )
        upsert(task)
    }

    func handleTaskNotification(_ notif: SystemMessage.TaskNotification) {
        guard let idx = tasks.firstIndex(where: { $0.id == notif.taskID }) else { return }
        var task = tasks[idx]
        task.status = Self.statusFrom(string: notif.status) ?? .completed
        if !notif.outputFile.isEmpty { task.outputFile = notif.outputFile }
        if !notif.summary.isEmpty { task.summary = notif.summary }
        task.endedAt = task.endedAt ?? Date()
        tasks[idx] = task
    }

    /// `system.task_updated` carries only the fields the CLI is changing
    /// this tick — most commonly `status` + end time on the terminal
    /// transition. Each is applied individually so a partial patch (an
    /// interim status flip with no end time yet) leaves the rest untouched.
    func handleTaskUpdated(_ updated: SystemMessage.TaskUpdated) {
        guard let idx = tasks.firstIndex(where: { $0.id == updated.taskID }) else { return }
        var task = tasks[idx]
        if let mapped = Self.statusFrom(string: updated.status) {
            task.status = mapped
        }
        if let endTime = updated.endTime {
            task.endedAt = endTime
        }
        if task.isTerminal, task.endedAt == nil {
            task.endedAt = Date()
        }
        tasks[idx] = task
    }

    /// The bash tool_result for a background invocation carries the
    /// spool-file path inside its text body. There is no structured field
    /// for it (`persistedOutputPath` is the persisted tail, not the live
    /// file), so parse the canonical sentence the CLI emits: "Output is
    /// being written to: <path>".
    func rememberOutputFileFromBashResult(_ user: UserMessage) {
        guard let block = user.toolResult else { return }
        let toolUseId = block.toolUseID
        // Use the tool_use_id to find the matching task (more reliable
        // than backgroundTaskId — the typed result carries the id, but
        // the text body has the path and the typed parse may or may not
        // populate every field). Tasks created by `handleTaskStarted` are
        // keyed on the CLI's task_id, but task_started always reports
        // both ids together, so a tool_use_id match is unambiguous.
        guard let idx = tasks.firstIndex(where: { $0.toolUseId == toolUseId })
        else { return }
        if let path = Self.extractOutputPath(from: block) {
            tasks[idx].outputFile = path
        }
    }

    /// Manually mark a task as stopped from the UI (popover stop button).
    /// The CLI will follow up with its own task_notification; in the
    /// meantime the card reads as stopped instead of spinning. Returns
    /// true when the entry existed.
    @discardableResult
    func markTaskStoppedLocally(taskId: String) -> Bool {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return false }
        guard tasks[idx].status == .running else { return true }
        tasks[idx].status = .stopped
        tasks[idx].endedAt = Date()
        return true
    }

    // MARK: - Helpers

    private func upsert(_ task: BackgroundTask) {
        if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
            // Preserve fields the upserted record may not have refreshed.
            var merged = task
            if merged.outputFile == nil { merged.outputFile = tasks[idx].outputFile }
            if merged.command == nil { merged.command = tasks[idx].command }
            if merged.summary == nil { merged.summary = tasks[idx].summary }
            tasks[idx] = merged
        } else {
            tasks.append(task)
        }
    }

    private static func statusFrom(string: String?) -> BackgroundTask.Status? {
        switch string?.lowercased() {
        case "completed": return .completed
        case "failed", "error", "exit_nonzero": return .failed
        case "stopped", "killed", "interrupted": return .stopped
        case "running", "in_progress", "started": return .running
        default: return nil
        }
    }

    /// Extract the spool-file path from the tool_result text body. The CLI
    /// has emitted one canonical sentence since this feature shipped:
    /// "Output is being written to: <absolute path>." We tolerate trailing
    /// punctuation and a missing leading whitespace just in case the CLI
    /// tightens its template.
    private static func extractOutputPath(from result: ToolResultBlock) -> String? {
        result.content.lazy.compactMap(\.text).compactMap(scanOutputPath(in:)).first
    }

    private static func scanOutputPath(in text: String) -> String? {
        let marker = "Output is being written to:"
        guard let range = text.range(of: marker) else { return nil }
        let tail = text[range.upperBound...]
        let trimmed = tail.drop(while: { $0.isWhitespace })
        // Read until the next whitespace — the CLI's spool path is a
        // single absolute POSIX path that does not contain spaces.
        // Dots are common (file extension `.output`, hidden dir
        // segments) so we cannot use them as terminators; the CLI
        // closes its sentence with a period AFTER the path which we
        // peel off in a second pass.
        var path = String(trimmed.prefix { !$0.isWhitespace })
        while let last = path.last, last == "." || last == "," {
            path.removeLast()
        }
        return path.isEmpty ? nil : path
    }
}
