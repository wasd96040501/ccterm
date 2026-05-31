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
    let coordSpace: String
    let submitEnabled: Bool
    let onSubmit: (InputBarView2.Submission) -> Void
    let onAttachRect: (CGRect) -> Void
    let onPillRect: (CGRect) -> Void
    /// Builtin slash command (`/new`, `/clear`) dispatcher. Forwarded to
    /// `InputBarView2`'s completion trigger context. Nil where builtins
    /// shouldn't be offered (the compose card).
    var onBuiltinCommand: ((BuiltinSlashCommand) -> Void)? = nil

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
                coordSpace: coordSpace,
                onAttachRect: onAttachRect,
                onPillRect: onPillRect,
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
                onBuiltinCommand: onBuiltinCommand
            )
            InputBarSessionChrome(session: session)
        }
        .task(id: prewarmKey) {
            CompletionPrewarmer.prewarm(prewarmKey)
        }
    }
}

/// Chat-mode resting input region: `InputBarChrome` plus the floating
/// `PermissionCardView` (when one is pending). The card is **layered
/// on the z-axis over the bar** — a `ZStack(alignment: .bottom)` whose
/// later child (the card) draws on top of and covers the bar, sharing
/// the same `chatBottomInset` so the card's bottom edge sits flush with
/// the chrome row and it extends *up* from there. It does NOT stack
/// above the bar on the y-axis (that pushed the bar down into a separate
/// tier and broke the floating-overlay look the card was designed for).
///
/// `ZStack` (not `.overlay`) is deliberate: an overlay is sized to its
/// host and never grows the parent, so under the bottom-anchored bar
/// host — whose height tracks this body's intrinsic content height — an
/// overlaid card would be clipped (and its upper half would fall outside
/// the host's hit-test bounds, killing its buttons). A `ZStack` reports
/// the union of its children, so the card's footprint correctly grows
/// the host to contain it. When no card is pending the ZStack collapses
/// back to the bar's height, so the host shrinks and the transcript
/// scroll view keeps receiving clicks in the empty band above the bar.
///
/// The card's `.frame(maxWidth: BlockStyle.maxLayoutWidth = 780)` is
/// hoisted out of `InputBarChrome`'s own `.frame(maxWidth: composeMaxWidth
/// = 512)` so it gets its full width budget — see the pre-AppKit
/// `RootView2` for the original geometry derivation.
///
/// `maxHeight: .infinity` is intentionally absent: the bar host is
/// bottom-anchored in `ChatSessionViewController`'s chat mode and takes
/// this body's intrinsic height via the host's `.intrinsicContentSize`.
struct ChatRestingBar: View {
    let sessionId: String
    let draftKey: String
    let onSubmit: (InputBarView2.Submission) -> Void
    let onAttachRect: (CGRect) -> Void
    let onPillRect: (CGRect) -> Void
    /// Builtin slash command (`/new`, `/clear`) dispatcher, forwarded to
    /// `InputBarChrome`. Non-nil in chat mode so the resting bar offers
    /// the builtins.
    var onBuiltinCommand: ((BuiltinSlashCommand) -> Void)? = nil

    @Environment(SessionManager.self) private var manager

    var body: some View {
        let session = manager.prepareDraftSession(sessionId)
        ZStack(alignment: .bottom) {
            InputBarChrome(
                sessionId: sessionId,
                draftKey: draftKey,
                coordSpace: ChatSessionViewController.detailCoordSpace,
                submitEnabled: true,
                onSubmit: onSubmit,
                onAttachRect: onAttachRect,
                onPillRect: onPillRect,
                onBuiltinCommand: onBuiltinCommand
            )
            .frame(
                minWidth: BlockStyle.minLayoutWidth,
                maxWidth: ChatSessionViewController.composeMaxWidth
            )
            .padding(.horizontal, ChatSessionViewController.detailHorizontalInset)

            if let pending = session.pendingPermissions.first {
                PermissionCardView(
                    request: pending.request,
                    onAllowOnce: { session.respond(to: pending.id, decision: pending.request.allowOnce()) },
                    onAllowAlways: {
                        session.respond(to: pending.id, decision: pending.request.allowAlways())
                    },
                    onDeny: { session.respond(to: pending.id, decision: pending.request.deny()) },
                    onAllowWithInput: { updated in
                        session.respond(
                            to: pending.id,
                            decision: pending.request.allowOnce(updatedInput: updated))
                    }
                )
                .frame(maxWidth: BlockStyle.maxLayoutWidth)
                .padding(.horizontal, ChatSessionViewController.detailHorizontalInset)
                .transition(
                    .scale(scale: 0.96, anchor: .bottom)
                        .combined(with: .opacity))
            }
        }
        .padding(.bottom, ChatSessionViewController.chatBottomInset)
        .frame(maxWidth: .infinity)
        .animation(.smooth(duration: 0.25), value: session.pendingPermissions.first?.id)
    }
}
