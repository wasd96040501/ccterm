import AgentSDK
import Foundation

// MARK: - Background task signals
//
// The CLI emits four message types around a background bash invocation:
//
//   1. `assistant.tool_use(Bash, run_in_background: true)` — the launch
//   2. `system.task_started` — task accepted, has task_id + tool_use_id
//      + description + task_type
//   3. `user.tool_result` — carries the absolute path of the spool file
//      ("Output is being written to: …") + the backgroundTaskId
//   4. `system.task_updated` (subtype the SDK does not model yet — comes
//      in as `.system(.unknown("task_updated", raw))`) — patches status
//      mid-flight and on completion
//   5. `system.task_notification` — terminal payload with status,
//      output_file, summary, usage. Triggers a synthetic follow-up turn
//      so the assistant can act on the result.
//
// None of those user-visible messages belong in the transcript: signals
// (2)/(4)/(5) are control-only and are intentionally dropped by the
// dispatch arms above. The matching tool_use+tool_result pair already
// renders as a tool group in the transcript; the popover surfaces
// long-running state for those tools off-band.

extension SessionRuntime {

    func handleTaskStarted(_ started: TaskStarted) {
        guard let taskId = started.taskId else { return }
        let command = bashCommand(forToolUseId: started.toolUseId)
        let existingOutputFile = tasks.first(where: { $0.id == taskId })?.outputFile
        let task = BackgroundTask(
            id: taskId,
            toolUseId: started.toolUseId,
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

    func handleTaskNotification(_ notif: TaskNotification) {
        guard let taskId = notif.taskId,
            let idx = tasks.firstIndex(where: { $0.id == taskId })
        else { return }
        var task = tasks[idx]
        task.status = Self.statusFrom(string: notif.status) ?? .completed
        if let path = notif.outputFile { task.outputFile = path }
        if let summary = notif.summary { task.summary = summary }
        task.endedAt = task.endedAt ?? Date()
        tasks[idx] = task
    }

    /// `system.task_updated` is shaped as `{task_id, patch: {status,
    /// end_time, …}}`. The SDK does not model it (it surfaces through
    /// the `.unknown` arm of `System`), so we read the patch out of the
    /// raw dict.
    func handleTaskUpdated(raw: [String: Any]) {
        guard let taskId = raw["task_id"] as? String,
            let idx = tasks.firstIndex(where: { $0.id == taskId })
        else { return }
        var task = tasks[idx]
        if let patch = raw["patch"] as? [String: Any] {
            if let statusStr = patch["status"] as? String,
                let mapped = Self.statusFrom(string: statusStr)
            {
                task.status = mapped
            }
            if let endTime = patch["end_time"] as? Double {
                task.endedAt = Date(timeIntervalSince1970: endTime / 1000.0)
            } else if let endTime = patch["end_time"] as? Int {
                task.endedAt = Date(timeIntervalSince1970: TimeInterval(endTime) / 1000.0)
            }
            if let outputFile = patch["output_file"] as? String {
                task.outputFile = outputFile
            }
            if let summary = patch["summary"] as? String {
                task.summary = summary
            }
        }
        if task.isTerminal, task.endedAt == nil {
            task.endedAt = Date()
        }
        tasks[idx] = task
    }

    /// The bash tool_result for a background invocation carries the
    /// spool-file path inside its text body. We don't have a structured
    /// field for it (ObjectBash.persistedOutputPath is for the persisted
    /// tail, not the live file), so parse the canonical sentence the CLI
    /// emits: "Output is being written to: <path>".
    func rememberOutputFileFromBashResult(_ user: Message2User) {
        guard let block = Self.firstToolResultBlock(in: user),
            let toolUseId = block.toolUseId
        else { return }
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

    private static func firstToolResultBlock(in user: Message2User) -> ItemToolResult? {
        guard case .array(let items) = user.message?.content else { return nil }
        for item in items {
            if case .toolResult(let r) = item { return r }
        }
        return nil
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

    private func bashCommand(forToolUseId toolUseId: String?) -> String? {
        guard let toolUseId else { return nil }
        for entry in messages.reversed() {
            switch entry {
            case .single(let s):
                if let cmd = Self.matchBashToolUse(s, toolUseId: toolUseId) {
                    return cmd
                }
            case .group(let g):
                for item in g.items.reversed() {
                    if let cmd = Self.matchBashToolUse(item, toolUseId: toolUseId) {
                        return cmd
                    }
                }
            }
        }
        return nil
    }

    private static func matchBashToolUse(_ single: SingleEntry, toolUseId: String) -> String? {
        guard case .remote(let m) = single.payload,
            case .assistant(let a) = m,
            let blocks = a.message?.content
        else { return nil }
        for block in blocks {
            guard case .toolUse(let tu) = block,
                tu.id == toolUseId,
                case .Bash(let bash) = tu
            else { continue }
            return bash.input?.command
        }
        return nil
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
    private static func extractOutputPath(from result: ItemToolResult) -> String? {
        let texts = result.content?.allText ?? []
        for text in texts {
            if let path = scanOutputPath(in: text) { return path }
        }
        return nil
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

// MARK: - Convenience

extension ItemToolResultContent {
    fileprivate var allText: [String] {
        switch self {
        case .string(let s): return [s]
        case .array(let items):
            return items.compactMap {
                if case .text(let t) = $0 { return t.text }
                return nil
            }
        case .other:
            return []
        }
    }
}
