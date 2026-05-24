import AppKit
import Observation

/// Synchronous, source-phase notification of a selection change.
///
/// The detail-side transition (swap the routed child VC, mount the new
/// session's transcript) must land in the **same** runloop iteration as
/// the click that triggered it — otherwise the transcript mount runs a
/// tick later than the SwiftUI input bar's `@Observable`-driven re-eval
/// and the switch visibly fragments across frames (see the root
/// CLAUDE.md runloop model: `withObservationTracking` re-arm hops are
/// async). `@Observable` alone can't give a synchronous post-change
/// hook, so the **structural** owner (`DetailRouterViewController`)
/// registers here and is driven inline from `select(_:)`. SwiftUI
/// consumers (input bar, sidebar cells) keep observing the `@Observable`
/// `selection` for their own content re-render — this delegate is
/// strictly additive, never a second source of truth.
@MainActor
protocol MainSelectionObserver: AnyObject {
    func selectionDidChange(to selection: MainSelection)
}

/// Top-of-window selection state, factored out of `RootView2`'s
/// `@State` cluster so the AppKit `MainSplitViewController` and its
/// SwiftUI-hosted children (sidebar, compose configurator, input bar
/// chrome) can all read/write the same source.
///
/// `@Observable` so SwiftUI hosting children re-render automatically
/// when fields flip. **Production mutations go through `select(_:)`**,
/// which drives the structural transition synchronously; direct
/// `selection =` assignment is reserved for pre-mount seeding (and
/// tests that drive the routed child manually).
@MainActor
@Observable
final class MainSelectionModel {
    /// What the sidebar currently has selected. Typed via `MainSelection`
    /// so each consumer's `switch` is exhaustive — "is this a real
    /// session or a sidebar tab" is no longer a runtime string-compare
    /// scattered across files.
    var selection: MainSelection = .newSession

    /// The structural owner of the detail-side transition. Set once by
    /// `DetailRouterViewController.viewDidLoad`. `@ObservationIgnored` so
    /// wiring the delegate never reads as an observable mutation.
    @ObservationIgnored weak var selectionObserver: MainSelectionObserver?

    /// Canonical selection mutator. Updates the `@Observable` value (so
    /// SwiftUI content observers re-render) and then **synchronously**
    /// notifies the structural observer so the routed child swap +
    /// transcript mount happen in the same source phase as the caller.
    /// No-op when the value is unchanged, so repeated clicks on the same
    /// row don't re-mount.
    func select(_ newSelection: MainSelection) {
        guard newSelection != selection else { return }
        selection = newSelection
        selectionObserver?.selectionDidChange(to: newSelection)
    }

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
