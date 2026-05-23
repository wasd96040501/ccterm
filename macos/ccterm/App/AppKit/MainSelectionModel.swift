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
    var selectedSessionId: String? = SidebarSentinel.newSession

    /// Mirrors `RootView2`'s `draftSessionId` — lazily allocated when
    /// the user enters the "New Session" tab, becomes the real
    /// `sessionId` after the first send.
    ///
    /// Compose-time configuration (cwd / useWorktree / sourceBranch /
    /// originPath) is **not** mirrored here — it lives on
    /// `Session.draft.config` directly, reached through
    /// `sessionManager.prepareDraftSession(draftSessionId)`. The
    /// `NewSessionConfigurator` bindings, the input bar's completion
    /// context, and the submit path all read the same `Session.draft`,
    /// so there's no second copy to keep in sync.
    var draftSessionId: String?

    /// Archive page's folder-filter selection. `nil` means "All
    /// Folders." Lifted out of `ArchiveView`'s local `@State` because
    /// the filter button now lives in the AppKit `NSToolbar` (the
    /// SwiftUI `.toolbar { }` modifier inside an `NSHostingController`
    /// child VC is silently dropped) — the button and `ArchiveView`
    /// share this field via the model.
    var archiveSelectedFolderPath: String?

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
        selectedSessionId == SidebarSentinel.newSession
    }

    /// The currently displayed sessionId, derived from the tab + draft.
    /// Mirrors `RootView2.effectiveSessionId`.
    var effectiveSessionId: String? {
        if selectedSessionId == SidebarSentinel.newSession {
            return draftSessionId
        }
        return selectedSessionId
    }
}
