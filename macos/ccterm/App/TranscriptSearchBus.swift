import Foundation

/// App-scope command bus for the chat transcript ⌘F / Find action.
///
/// The search field is always-on (mounted as a `.primaryAction`
/// `ToolbarItem` in `ChatHistoryView`), so there is nothing to
/// "open". What ⌘F still needs to do is hand keyboard focus to the
/// field even when another control had it. The Find menu item lives
/// on the `App` scene; the field's `@FocusState` lives per-
/// `ChatHistoryView`. This counter is the SwiftUI-native, lifecycle-
/// safe bridge between them.
///
/// `@Observable` + `.environment()` + `.onChange(of:)` is used instead of
/// `NotificationCenter` because the per-view subscriber lives behind a
/// SwiftUI `.id(sessionId)` boundary (`ChatHistoryView` is rebuilt on
/// session swap). `focusRequestCounter` is monotonically bumped so
/// back-to-back invocations register even though the value never
/// "settles" at a unique state.
@Observable
@MainActor
final class TranscriptSearchBus {
    /// Bump-on-request counter. `ChatSearchBarView` watches this via
    /// `.onChange(of:)` and sets `isFocused = true` each time the
    /// value changes. Initial value is `0`; first invocation produces
    /// `1`, which is a real `change` event.
    private(set) var focusRequestCounter: Int = 0

    func requestFocus() {
        focusRequestCounter &+= 1
    }
}
