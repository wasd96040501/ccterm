import Foundation

/// App-scope command bus for the chat transcript ⌘F / Find action.
///
/// The search field is always-on (rendered by SwiftUI's `.searchable`
/// modifier in the window toolbar), so there is nothing to "open".
/// What ⌘F still needs to do is hand keyboard focus to the field even
/// when another control had it. The Find menu item lives on the `App`
/// scene; the field's `@FocusState` (driven by `.searchFocused`) lives
/// on the toolbar's `NSSearchToolbarItem`. This counter is the
/// lifecycle-safe bridge between them.
///
/// `@Observable` + `.environment()` + `.onChange(of:)` is used instead of
/// `NotificationCenter` because the per-view subscriber lives behind a
/// session-id boundary that may be rebuilt on session swap.
/// `focusRequestCounter` is monotonically bumped so back-to-back
/// invocations register even though the value never "settles" at a
/// unique state.
@Observable
@MainActor
final class TranscriptSearchBus {
    /// Bump-on-request counter. The toolbar search field watches this
    /// via `.onChange(of:)` and sets `isSearchFocused = true` each time
    /// the value changes. Initial value is `0`; first invocation
    /// produces `1`, which is a real `change` event.
    private(set) var focusRequestCounter: Int = 0

    func requestFocus() {
        focusRequestCounter &+= 1
    }

    /// macOS 26 SDK workaround — see `Session.deinit` for background.
    /// `nonisolated` skips `swift_task_deinitOnExecutorImpl` which
    /// traps for `@Observable @MainActor` classes on tear-down.
    nonisolated deinit {}
}
