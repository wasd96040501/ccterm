import AppKit

/// Shared dispatcher for the builtin `/new` and `/clear` slash commands.
/// Both create a fresh draft session that inherits the triggering
/// session's metadata (cwd / worktree / branch / model / effort /
/// permission mode / dirs), surface it as an auto-focused sidebar row, and
/// land on the draft-landing page. `/clear` additionally archives the
/// triggering session first.
///
/// Wired as the `onBuiltinCommand` closure handed to `InputBarChrome` (the
/// chat resting bar and the draft-landing bar). A free function rather
/// than a VC method — mirrors `submitSessionInput` — so the chat and
/// draft-landing code paths can't drift.
@MainActor
func runBuiltinSlashCommand(
    _ command: BuiltinSlashCommand,
    currentSessionId: String?,
    sessionManager: SessionManager,
    model: MainSelectionModel
) {
    // Order is load-bearing:
    //   1. Create the new draft FIRST, copying metadata while the source
    //      session is still live. `/clear`'s archive (step 2) stops the
    //      source CLI and removes its worktree on a background queue, so
    //      reading the source's config after archive would race teardown.
    //   2. Archive the source (only `/clear`). The new draft re-provisions
    //      its own worktree under a freshly-generated name at first send
    //      (`Worktree.generateName`), so deleting the source worktree can
    //      never collide with it.
    //   3. Select the new draft. `select` (not `promote`) is correct here:
    //      the new id always differs from the current selection, so this is
    //      a normal transition into the draft-landing page.
    let draftId = sessionManager.createSidebarDraft(seededFrom: currentSessionId)
    if command == .clear, let currentSessionId {
        sessionManager.archive(currentSessionId)
    }
    model.select(.session(draftId))
}
