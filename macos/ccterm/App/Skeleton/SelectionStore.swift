import Combine
import Foundation

/// Window-scope Store owning the current sidebar selection + the two
/// selection-adjacent slivers (`draftSessionId`, `archiveSelectedFolderPath`).
/// Combine `@Published` — no `@Observable`, no `import SwiftUI`.
///
/// **Data-down consumers** (view display: sidebar highlight, toolbar
/// project chip, archive-filter icon, input-bar chrome once migrated)
/// subscribe to the individual `$` publishers via `.sink` and update
/// their view. Consumers must `.store(in: &cancellables)` and capture
/// `[weak self]` inside the sink.
///
/// **Events-up writers** are coordinators only. `select(_:)` /
/// `promote(to:)` / `setArchiveFolder(_:)` are called by
/// `MainWindowCoordinator` / `DetailFlowCoordinator` after they receive
/// a semantic event from a VC delegate. Coordinators do NOT `sink` on
/// this store — they mutate it. That preserves the CLAUDE.md discipline
/// "VC reports semantic events; Coordinator decides routing", without
/// the store becoming a routing bus.
@MainActor
final class SelectionStore {
    @Published var selection: MainSelection = .newSession
    @Published var draftSessionId: String?
    @Published var archiveSelectedFolderPath: String?

    init() {}

    /// Idempotent selection setter. No-op when the target is already
    /// current — the router doesn't re-mount the same child, and the
    /// sidebar's highlight-sink doesn't reissue the same `selectRow`.
    func select(_ newSelection: MainSelection) {
        guard newSelection != selection else { return }
        selection = newSelection
    }

    /// Re-fire the selection change for the same value. Used after a
    /// draft's first send promotes the phase `.draft → .active`: the
    /// selection value is unchanged (`.session(sid)` both before and
    /// after), but the router needs to re-evaluate the child kind
    /// (draft-landing → history session).
    ///
    /// Publishers only fire on `!=`, so a straight assignment would be
    /// swallowed. Two options exist and both work here — pick the one
    /// consumers actually observe: coordinators receive the `promote`
    /// call directly (they don't sink), and every current display
    /// consumer only cares about the value going through a real change,
    /// so a bounce through `.none` would flicker the sidebar highlight
    /// mid-tick. Instead the coordinator that calls this explicitly
    /// re-runs its routing on the same value.
    func promote(to sessionId: String) {
        // Kept as a semantic entry point for the coordinator to call.
        // If the selection has already moved to a different session,
        // fall back to a normal `select(_:)` into the target.
        let target = MainSelection.session(sessionId)
        if selection == target { return }
        selection = target
    }

    func setArchiveFolder(_ path: String?) {
        guard archiveSelectedFolderPath != path else { return }
        archiveSelectedFolderPath = path
    }

    func setDraftSessionId(_ id: String?) {
        guard draftSessionId != id else { return }
        draftSessionId = id
    }

    /// Convenience derived value. Not `@Published` on purpose — every
    /// callsite reads it on demand off `selection` + `draftSessionId`.
    var effectiveSessionId: String? {
        switch selection {
        case .newSession: return draftSessionId
        case .session(let sid): return sid
        case .none, .archive: return nil
        }
    }

    /// Deallocation runs on any thread. Every stored member (enum, `String?`,
    /// Combine subject) tears down safely; keeping `deinit` `nonisolated`
    /// dodges the macOS 26 `TaskLocal::StopLookupScope` teardown bug the rest
    /// of the codebase already guards against.
    nonisolated deinit {}
}
