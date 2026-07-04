import AppKit

/// The upward channel from the thin `MainWindowController` to its
/// coordinator. Every toolbar / window event the controller sees
/// (search field typing / return / previous, window will-close, ⌘F
/// focus request handled here for visibility) is reported through this
/// protocol; the coordinator decides what to do with it.
///
/// The controller never reaches into `SelectionStore` / `SessionManager`
/// / `AppContext` directly — routing decisions belong to the
/// coordinator.
@MainActor
protocol MainWindowControllerDelegate: AnyObject {
    func mainWindowControllerWillClose(_ controller: MainWindowController)
    func mainWindowController(
        _ controller: MainWindowController,
        searchQueryDidChange query: String
    )
    func mainWindowController(
        _ controller: MainWindowController,
        searchDidRequestNext shift: Bool
    )
    func mainWindowController(
        _ controller: MainWindowController,
        archiveFilterDidSelectFolderPath path: String?
    )
}
