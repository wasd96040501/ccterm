import AgentSDK
import Foundation

// MARK: - Bash command back-fill
//
// The task lifecycle itself lives on `TaskTracker` (the `@Observable`
// projection owned by `SessionRuntime`). The one piece that can't move
// there is the command back-fill: `system.task_started` does not echo
// the shell command, so we reverse-scan the message timeline for the
// originating `assistant.tool_use(Bash)` and pull `input.command` out
// of it. That scan needs `messages`, which only the runtime holds, so
// `receive` resolves the command here and passes it into
// `taskTracker.handleTaskStarted(_:command:)`.

extension SessionRuntime {

    func bashCommand(forToolUseId toolUseId: String?) -> String? {
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

    /// Thin forwarder kept so the `Session.stopBackgroundTask` façade
    /// doesn't have to reach into `runtime.taskTracker`. Marks a task
    /// stopped on the projection.
    @discardableResult
    func markTaskStoppedLocally(taskId: String) -> Bool {
        taskTracker.markTaskStoppedLocally(taskId: taskId)
    }
}
