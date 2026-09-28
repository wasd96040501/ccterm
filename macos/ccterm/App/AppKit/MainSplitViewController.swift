import AppKit
import TranscriptWorkspace

/// The main window's sidebar/detail split: the session library on the left,
/// an Xcode-style editor area — tabs, two editors side by side — on the right.
/// Routes between them: a node opened in the sidebar becomes a tab, or
/// selects the tab that already shows it.
@MainActor
final class MainSplitViewController: NSSplitViewController {
    private let sidebarViewController: SidebarViewController
    private let editorArea = EditorAreaViewController()

    init(library: LibraryStore) {
        sidebarViewController = SidebarViewController(library: library)
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

        let detailItem = NSSplitViewItem(viewController: editorArea)
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

    override func viewDidLoad() {
        super.viewDidLoad()
        sidebarViewController.delegate = self
        editorArea.delegate = self
    }
}

extension MainSplitViewController: SidebarViewControllerDelegate {
    /// A transcript opens once: already open in either editor, its tab is
    /// selected there, and the active editor stays where the reader is —
    /// nothing in the window aims at the active editor yet.
    func sidebarViewController(_ sidebar: SidebarViewController, didOpen node: LibraryNode) {
        guard let url = node.transcriptURL else { return }
        for group in editorArea.groups {
            let index = group.tabViewItems.firstIndex {
                ($0.viewController as? TranscriptViewController)?.fileURL == url
            }
            if let index {
                group.selectedTabViewItemIndex = index
                return
            }
        }
        let tab = TranscriptViewController(fileURL: url, title: node.title)
        editorArea.activeGroup.addTabViewItem(NSTabViewItem(viewController: tab))
    }
}

extension MainSplitViewController: EditorAreaViewControllerDelegate {
    func editorArea(_ editorArea: EditorAreaViewController, willClose viewController: NSViewController) {
        (viewController as? TranscriptViewController)?.prepareForRemoval()
    }
}
