import AppKit

/// The main window's sidebar/detail split. Both sides are empty panes until
/// the session list and the transcript (`TranscriptKit`) are wired in; the
/// split itself — thickness limits, collapse, divider autosave — is final.
@MainActor
final class MainSplitViewController: NSSplitViewController {
    private let sidebarViewController = EmptyPaneViewController()
    private let detailViewController = EmptyPaneViewController()

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        super.loadView()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 350
        // First-launch width when no autosaved divider position exists.
        // 0.22 of a 1200pt default window → 264pt, inside [220, 350].
        // Once autosave kicks in this is ignored.
        sidebarItem.preferredThicknessFraction = 0.22
        sidebarItem.canCollapse = true
        sidebarItem.titlebarSeparatorStyle = .automatic
        addSplitViewItem(sidebarItem)

        let detailItem = NSSplitViewItem(viewController: detailViewController)
        detailItem.minimumThickness = 680
        detailItem.canCollapse = false
        detailItem.titlebarSeparatorStyle = .none
        addSplitViewItem(detailItem)

        splitView.dividerStyle = .thin
        // Persist the user's divider position (and collapsed state)
        // across launches. Set after both items are added — AppKit
        // restores the saved frames on the next layout pass.
        splitView.autosaveName = "ccterm.mainSplit"
    }
}

/// A pane with nothing in it — the stand-in for each side of the split.
@MainActor
private final class EmptyPaneViewController: NSViewController {
    override func loadView() {
        view = NSView()
    }
}
