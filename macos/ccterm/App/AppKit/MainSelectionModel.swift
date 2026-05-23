import AppKit
import Observation

/// Top-of-window selection state, factored out of `RootView2`'s
/// `@State` cluster so the AppKit `MainSplitViewController` and its
/// SwiftUI-hosted children (sidebar, compose configurator, input bar
/// chrome) can all read/write the same source.
///
/// `@Observable` so SwiftUI hosting children re-render automatically
/// when fields flip; mutations from inside the detail VC simply assign
/// the property.
@MainActor
@Observable
final class MainSelectionModel {
    /// Mirrors `RootView2`'s `selectedSessionId` — the sidebar's
    /// selected item (a session id, `__new_session__`, `__archive__`,
    /// or one of the DEBUG demo sentinels).
    var selectedSessionId: String? = SidebarView2.newSessionTag

    /// Mirrors `RootView2`'s `draftSessionId` — lazily allocated when
    /// the user enters the "New Session" tab, becomes the real
    /// `sessionId` after the first send.
    var draftSessionId: String?

    /// Folder picked in `NewSessionConfigurator`. Becomes the
    /// session's `originPath` (and `cwd` unless worktree is on) at
    /// first-send time.
    var draftCwd: String?

    /// Compose-time worktree-provisioning flag. Ignored when the
    /// chosen folder isn't a git repo (the configurator disables it).
    var draftUseWorktree: Bool = false

    /// Source branch fed into `Worktree.create`'s `sourceBranch`.
    /// nil → repo's current branch (Worktree falls back to detached
    /// check).
    var draftSourceBranch: String?

    /// Frame of the round attach button, in the detail-pane
    /// coordinate space. The bottom scrim cuts a `Circle` hole here.
    var attachRect: CGRect = .zero

    /// Frame of the rounded-rectangle pill, in the detail-pane
    /// coordinate space. The bottom scrim cuts a `RoundedRectangle`
    /// hole here.
    var pillRect: CGRect = .zero

    /// True when the New Session tab is selected. Once `submit(...)`
    /// flips `selectedSessionId` to the concrete draft UUID, this
    /// turns false and the detail VC settles the input bar at its
    /// chat-mode resting position.
    var isComposeMode: Bool {
        selectedSessionId == SidebarView2.newSessionTag
    }

    /// The currently displayed sessionId, derived from the tab + draft.
    /// Mirrors `RootView2.effectiveSessionId`.
    var effectiveSessionId: String? {
        if selectedSessionId == SidebarView2.newSessionTag {
            return draftSessionId
        }
        return selectedSessionId
    }
}
