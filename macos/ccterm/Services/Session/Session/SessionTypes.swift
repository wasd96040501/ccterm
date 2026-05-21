import AgentSDK
import Foundation

/// A pending permission request from the CLI awaiting decision. Holds the
/// request content and a response closure. The UI shows the request, and
/// once the user decides, calling `respond` sends the decision back to the
/// CLI and removes the entry from the list.
struct PendingPermission: Identifiable {
    let id: String
    let request: PermissionRequest
    /// Reply to the CLI. The closure removes the entry from
    /// pendingPermissions on its own.
    let respond: (PermissionDecision) -> Void
}

/// A slash command advertised by the CLI during initialize.
struct SlashCommand {
    let name: String
    let description: String?
}

/// Payload for "an assistant turn just ended on this session." Produced
/// by `SessionRuntime` at the `.responding` → `.idle` edge and consumed
/// by the notification service. Values are already user-display ready:
/// `title` carries the session's display title with empty-state
/// fallback already applied; `body` is the last assistant text snapshot
/// (raw, not yet truncated — the consumer applies its own cap).
struct TurnEndedNotice {
    let sessionId: String
    let title: String
    let body: String
}

/// A background bash task spawned by the CLI's `Bash` tool with
/// `run_in_background: true`. Tracked off the transcript timeline so we
/// can surface live status in the input bar's task popover instead of
/// scattering control signals (task_started / task_updated /
/// task_notification system messages) as user bubbles.
struct BackgroundTask: Identifiable, Equatable {

    enum Status: Equatable {
        /// Task is still running (no terminal task_notification or
        /// task_updated patch with a terminal status seen yet).
        case running
        /// Task ran to completion (exit code 0 reported by the CLI).
        case completed
        /// Task ran but exited with a non-zero code.
        case failed
        /// User killed the task via /tasks or the popover's stop.
        case stopped
    }

    /// CLI-assigned task id (e.g. `bxrhxgxqo`). Stable across the
    /// lifetime of the task.
    let id: String
    /// The `tool_use_id` of the assistant's `Bash` invocation. Used both
    /// as a back-pointer for command lookup and to match task_notification
    /// / task_updated payloads.
    let toolUseId: String?
    /// Free-form description supplied by the assistant in the Bash tool
    /// input (`description` field). The CLI echoes this back through
    /// task_started. Shown as the card title.
    var description: String?
    /// CLI's task category (`local_bash` for now). Reserved for future
    /// remote-bash / agent tasks; we render it as a small subtitle.
    var taskType: String?
    /// The actual shell command being executed. Captured from the
    /// matching `assistant.tool_use.input.command` block — the CLI does
    /// not echo it in task_started.
    var command: String?
    /// Absolute path of the file the CLI streams stdout+stderr to. Known
    /// from the tool_result returned for the Bash call ("Output is being
    /// written to: …") and re-confirmed by task_notification.
    var outputFile: String?
    /// Wall-clock time at which the local runtime first saw the task.
    let startedAt: Date
    /// Wall-clock time at which the task transitioned to a terminal
    /// state. Nil while running.
    var endedAt: Date?
    var status: Status
    /// Human-readable summary from task_notification (e.g. "Background
    /// command \"X\" completed (exit code 0)"). Rendered as the
    /// completion footer on the card.
    var summary: String?

    var isTerminal: Bool {
        status != .running
    }
}

/// Normalize a user message into a single-line sidebar title:
/// collapse newlines into spaces, trim surrounding whitespace, and
/// truncate to `maxLength` characters (appending `…` when cut). Result
/// may be empty when the input is whitespace-only — callers should
/// guard against that.
///
/// Used by `Session.send(text:)` during draft → runtime promotion to
/// seed `runtime.title` before the first persist, and as a pure helper
/// for tests that want to assert on the derivation.
func deriveTitleFromFirstMessage(_ text: String, maxLength: Int = 80) -> String {
    let oneLine =
        text
        .replacingOccurrences(of: "\r\n", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
    let trimmed = oneLine.trimmingCharacters(in: .whitespaces)
    if trimmed.count > maxLength {
        return trimmed.prefix(maxLength) + "…"
    }
    return trimmed
}
