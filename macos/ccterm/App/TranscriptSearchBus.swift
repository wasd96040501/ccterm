import Foundation

/// App-scope command bus for the chat transcript ⌘F / Find action.
///
/// `AppCommands`' Find menu item lives on the `App` scene; the search
/// bar's `isSearchVisible` lives per-`ChatHistoryView`. We need a way
/// for the scene-scope menu to signal the per-view state without:
///
/// 1. A global mutable singleton (untrackable side effects), or
/// 2. `NotificationCenter` (observed to not deliver reliably when
///    SwiftUI is the publisher and the subscriber is a `.onReceive`
///    inside a view that lives behind a SwiftUI `.id(...)` boundary).
///
/// `@Observable` + `.environment()` + `.onChange(of:)` is the
/// SwiftUI-native, lifecycle-safe path. `openRequestCounter` is
/// monotonically bumped so back-to-back invocations register even
/// though the value never "settles" at a unique state.
@Observable
@MainActor
final class TranscriptSearchBus {
    /// Bump-on-request counter. ChatHistoryView watches this via
    /// `.onChange(of:)` and toggles its `isSearchVisible` each time
    /// the value changes. Initial value is `0`; first invocation
    /// produces `1`, which is a real `change` event.
    private(set) var openRequestCounter: Int = 0

    func requestOpen() {
        openRequestCounter &+= 1
    }
}
