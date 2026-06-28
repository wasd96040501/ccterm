import AgentSDK
import SwiftUI

/// Per-session wrapper around `InputBarView2`. Resolves the
/// `Session` so the bar can read `isRunning` (send↔stop swap)
/// and call `interrupt()`, and hosts the session-scoped chrome row
/// (`InputBarSessionChrome`) directly below the bar — kept *outside*
/// the pill so the bar itself stays "pure UI" and the chrome row can
/// align its left/right edges with the bar (attach button on the left,
/// pill's trailing edge on the right). The running indicator now lives
/// at the tail of the transcript (`Transcript2Controller.setLoading`).
struct InputBarChrome: View {
    let sessionId: String
    let draftKey: String
    let submitEnabled: Bool
    let onSubmit: (InputBarView2.Submission) -> Void
    /// Builtin slash command (`/new`, `/clear`) dispatcher. Forwarded to
    /// `InputBarView2`'s completion trigger context. Nil where builtins
    /// shouldn't be offered (the compose card).
    var onBuiltinCommand: ((BuiltinSlashCommand) -> Void)? = nil
    /// Forwarded to `InputBarView2`: auto-focus the text field on appear.
    /// True only for the `/new` / `/clear` draft-landing bar.
    var autofocus: Bool = false

    @Environment(SessionManager.self) private var manager

    /// Resolved synchronously per render. `prepareDraftSession` is
    /// idempotent get-or-create (pure in-memory), and returns the same
    /// instance `ChatSessionViewController` holds.
    private var session: Session {
        manager.prepareDraftSession(sessionId)
    }

    /// Cache key for the prewarm task. SwiftUI re-fires the `.task` only
    /// when this value changes, so it ends up firing once per (cwd /
    /// addDirs / pluginDirs) combination — both on the initial entry
    /// into the session and on every folder switch.
    private var prewarmKey: CompletionPrewarmer.Key {
        CompletionPrewarmer.Key(
            directory: session.cwd,
            additionalDirs: session.additionalDirectories,
            pluginDirs: session.pluginDirectories
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InputBarSessionChrome.barSpacing) {
            InputBarView2(
                onSubmit: onSubmit,
                onStop: { session.interrupt() },
                isRunning: session.isRunning,
                submitEnabled: submitEnabled,
                directory: session.cwd,
                additionalDirs: session.additionalDirectories,
                pluginDirs: session.pluginDirectories,
                // Live-list shortcut: once the CLI's `initialize` response
                // has populated `session.slashCommands`, pass that list
                // directly so the rule's provider skips the temp-CLI
                // fetch. Until then — compose mode (no runtime yet) and
                // chat mode in the brief window between session attach
                // and `adopt(Init)` — leave this `nil` so the rule falls
                // back to the per-cwd `SlashCommandStore` cache, which
                // the same view's `.task(id: prewarmKey)` is already
                // warming.
                knownSlashCommands: session.slashCommands.isEmpty ? nil : session.slashCommands,
                draftKey: draftKey,
                onBuiltinCommand: onBuiltinCommand,
                autofocus: autofocus
            )
            InputBarSessionChrome(session: session)
        }
        .task(id: prewarmKey) {
            CompletionPrewarmer.prewarm(prewarmKey)
        }
    }
}

/// Chat-mode resting input region: just `InputBarChrome`, bottom-padded
/// and width-capped. The floating `PermissionCardView` is **not** here —
/// it's composited as a higher z-layer in the same `ChatBottomCluster`
/// tree by `ChatSessionViewController`. Keeping the card out of this body
/// is the whole point: when the card was a `ZStack` child here, its
/// footprint pumped the union height this body reports, and the
/// bottom-anchored cluster host (regime-B, `.intrinsicContentSize`) grew to
/// contain it — the bar band visibly ballooned up when a card appeared. Now
/// this body's intrinsic height is a pure function of the bar's own content
/// (multi-line input still grows it), fully decoupled from the card.
struct ChatRestingBar: View {
    let sessionId: String
    let draftKey: String
    let onSubmit: (InputBarView2.Submission) -> Void
    /// Builtin slash command (`/new`, `/clear`) dispatcher, forwarded to
    /// `InputBarChrome`. Non-nil in chat mode so the resting bar offers
    /// the builtins.
    var onBuiltinCommand: ((BuiltinSlashCommand) -> Void)? = nil

    var body: some View {
        InputBarChrome(
            sessionId: sessionId,
            draftKey: draftKey,
            submitEnabled: true,
            onSubmit: onSubmit,
            onBuiltinCommand: onBuiltinCommand
        )
        .frame(
            minWidth: BlockStyle.minLayoutWidth,
            maxWidth: ChatSessionViewController.composeMaxWidth
        )
        .padding(.horizontal, ChatSessionViewController.detailHorizontalInset)
        .padding(.bottom, ChatSessionViewController.chatBottomInset)
        .frame(maxWidth: .infinity)
    }
}
