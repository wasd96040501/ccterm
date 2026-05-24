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

    @Environment(SessionManager.self) private var manager

    /// Resolved synchronously per render. `prepareDraftSession` is
    /// idempotent get-or-create (pure in-memory), and returns the same
    /// instance `TranscriptDetailViewController` holds.
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
                draftKey: draftKey
            )
            InputBarSessionChrome(session: session)
        }
        .task(id: prewarmKey) {
            CompletionPrewarmer.prewarm(prewarmKey)
        }
    }
}

/// Chat-mode resting input region: bottom-anchored `InputBarChrome`
/// plus the floating `PermissionCardView` overlay.
///
/// The card is hosted *here* — outside `InputBarChrome`'s own
/// `.frame(maxWidth: composeMaxWidth = 512)` — so its `.frame(maxWidth:
/// BlockStyle.maxLayoutWidth = 780)` is no longer silently clipped to
/// 512 by the bar's host frame. Vertical alignment and horizontal
/// centering are preserved bit-for-bit; see the pre-AppKit-migration
/// `RootView2` for the geometry derivation.
struct ChatRestingBar: View {
    let sessionId: String
    let draftKey: String
    let onSubmit: (InputBarView2.Submission) -> Void
    let onAttachRect: (CGRect) -> Void
    let onPillRect: (CGRect) -> Void

    @Environment(SessionManager.self) private var manager

    var body: some View {
        let session = manager.prepareDraftSession(sessionId)
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            InputBarChrome(
                sessionId: sessionId,
                draftKey: draftKey,
                coordSpace: TranscriptDetailViewController.detailCoordSpace,
                submitEnabled: true,
                onSubmit: onSubmit,
                onAttachRect: onAttachRect,
                onPillRect: onPillRect
            )
            .frame(
                minWidth: BlockStyle.minLayoutWidth,
                maxWidth: TranscriptDetailViewController.composeMaxWidth
            )
            .padding(.horizontal, TranscriptDetailViewController.detailHorizontalInset)
            .padding(.bottom, TranscriptDetailViewController.chatBottomInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
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
                .padding(.horizontal, TranscriptDetailViewController.detailHorizontalInset)
                .padding(.bottom, TranscriptDetailViewController.chatBottomInset)
                .transition(
                    .scale(scale: 0.96, anchor: .bottom)
                        .combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: session.pendingPermissions.first?.id)
    }
}
