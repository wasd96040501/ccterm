import Foundation

/// Window-scope dependency manifest. Built by `AppCoordinator` when it
/// creates a `MainWindowCoordinator`, and passed straight through to
/// the window controller / split VC / detail flow. Read-only.
///
/// Adds two window-lifetime stores on top of the process-scope
/// `AppContext`: the shared selection state (`selectionStore`) and
/// the ⌘F focus bus (`searchBus`). Both are created per window — a
/// second window (should we add one later) would get its own instances
/// and be independently searchable / selectable.
@MainActor
struct WindowContext {
    let app: AppContext
    let selectionStore: SelectionStore
    let searchBus: SearchBusService
}
