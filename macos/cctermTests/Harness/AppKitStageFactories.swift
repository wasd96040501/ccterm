import AgentSDK
import AppKit
import Combine

@testable import ccterm

/// Factory entry points that assemble **real** production view trees and
/// return them mounted in an `AppKitStage`, plus the queries a test needs
/// against the tree a factory built.
extension AppKitStage {

    // MARK: - Main-split factory

    /// Mount the real `MainSplitViewController` — the main window's content
    /// — exactly as `MainWindowController` constructs it. The library is
    /// unstarted unless the caller starts it; by default it is one over a
    /// directory that doesn't exist, so the sidebar is empty.
    static func mainSplit(library: LibraryStore? = nil, size: CGSize = defaultWindowSize) -> AppKitStage {
        let library =
            library
            ?? LibraryStore(
                directories: Just(
                    SessionDirectory(
                        url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
                ).eraseToAnyPublisher())
        return mount(MainSplitViewController(library: library), size: size)
    }

    // MARK: - Main-window factory

    /// Mount the real `MainWindowController` — its titled, full-size-content
    /// window, its toolbar, and the main split in it — as `AppDelegate` builds
    /// it, minus the frame autosave the composition root adds. The library is
    /// as `mainSplit`'s.
    static func mainWindow(library: LibraryStore? = nil, size: CGSize = defaultWindowSize) -> AppKitStage {
        let library =
            library
            ?? LibraryStore(
                directories: Just(
                    SessionDirectory(
                        url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
                ).eraseToAnyPublisher())
        return mount(MainWindowController(library: library, git: GitService()), size: size)
    }

    // MARK: - Mounted-VC accessors

    /// The mounted `MainSplitViewController`, or nil if this stage was built
    /// by a different factory.
    var mainSplit: MainSplitViewController? {
        rootViewController as? MainSplitViewController
    }

    /// Width of the sidebar pane (the leading split item's view), in the
    /// split's coordinate space. Nil unless this is a `mainSplit` stage.
    /// Use it so an assertion needn't hard-code the sidebar's autosaved
    /// thickness.
    var sidebarWidth: CGFloat? {
        guard let split = mainSplit, let first = split.splitViewItems.first else { return nil }
        return first.viewController.view.frame.width
    }

    /// Width of the detail pane (the trailing split item's view). Nil unless
    /// this is a `mainSplit` stage. This — not the window width — is the
    /// space detail content actually lays out in.
    var detailPaneWidth: CGFloat? {
        guard let split = mainSplit, split.splitViewItems.count >= 2 else { return nil }
        return split.splitViewItems[1].viewController.view.frame.width
    }
}
