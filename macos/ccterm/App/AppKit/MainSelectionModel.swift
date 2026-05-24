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
    /// What the sidebar currently has selected. Typed via `MainSelection`
    /// so each consumer's `switch` is exhaustive — "is this a real
    /// session or a sidebar tab" is no longer a runtime string-compare
    /// scattered across files.
    var selection: MainSelection = .newSession

    /// Lazily allocated when the user enters the "New Session" tab,
    /// becomes the real `sessionId` after the first send.
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

    /// True when the New Session tab is selected. Once `submit(...)`
    /// flips `selection` to `.session(...)`, this turns false and the
    /// detail VC settles the input bar at its chat-mode resting position.
    var isComposeMode: Bool {
        selection == .newSession
    }

    /// The currently displayed sessionId, derived from selection +
    /// draft. Returns `nil` for tabs that don't correspond to a session
    /// (`.none`, `.archive`, `.demo`).
    var effectiveSessionId: String? {
        switch selection {
        case .newSession: return draftSessionId
        case .session(let sid): return sid
        case .none, .archive: return nil
        #if DEBUG
        case .demo: return nil
        #endif
        }
    }
}
