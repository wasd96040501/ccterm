import Cocoa

/// CCTerm-native slash commands offered in the chat input bar's `/`
/// completion popup, distinct from the CLI-provided commands surfaced by
/// `SlashCommandStore`. A CLI command splices `/name ` into the input for
/// the user to send; a builtin instead fires an in-app action the moment
/// it's confirmed (see `runBuiltinSlashCommand`) and clears the input.
///
/// Availability is gated by `CompletionTriggerContext.onBuiltinCommand`:
/// the chat resting bar and the draft-landing bar wire a dispatcher (so
/// builtins appear), while the New Session compose card leaves it nil — on
/// that card `/new` is redundant and there's no session to `/clear`.
enum BuiltinSlashCommand: String, CaseIterable {
    /// Spin up a fresh draft session (auto-focused in the sidebar) that
    /// inherits the triggering session's directory / worktree / model.
    case new
    /// Like `.new`, but first archives the triggering session.
    case clear

    /// `/new` / `/clear` — matches the `displayText` of a CLI command so
    /// the popup row reads identically.
    var displayText: String { "/\(rawValue)" }

    /// Popup detail line. Localized.
    var detail: String {
        switch self {
        case .new: return String(localized: "Start a new session in this project")
        case .clear: return String(localized: "Archive this session and start a new one")
        }
    }
}

/// `CompletionItem` wrapper so a `BuiltinSlashCommand` can ride the same
/// completion popup as `SlashCommandStore.Match`. `SlashCommandTriggerRule`
/// detects this concrete type (`item is BuiltinCompletionItem`) to fire the
/// app action + clear the input instead of splicing text.
struct BuiltinCompletionItem: CompletionItem {
    let command: BuiltinSlashCommand

    var displayText: String { command.displayText }
    var displayDetail: String? { command.detail }
    var displayIcon: NSImage? { nil }
}
