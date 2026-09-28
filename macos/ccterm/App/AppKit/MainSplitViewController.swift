import AppKit
import TranscriptWorkspace

/// The main window's sidebar/detail split: the session library on the left,
/// an Xcode-style editor area — tabs, two editors side by side — on the right.
///
/// Routes between them the way Xcode's navigator does: a transcript already
/// open is selected where it is; otherwise selecting it in the sidebar shows
/// it in the active editor's temporary tab, and double-clicking it opens a tab
/// that stays. Dragged from the sidebar, it opens where it is dropped.
@MainActor
final class MainSplitViewController: NSSplitViewController {
    private let library: LibraryStore
    private let sidebarViewController: SidebarViewController
    private let editorArea = EditorAreaViewController()

    init(library: LibraryStore) {
        self.library = library
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
        editorArea.registerForDraggedTypes([.fileURL])
    }

    // MARK: - Commands

    /// File > Close Tab: the active editor's selected tab, else the window.
    @objc func closeTab(_ sender: Any?) {
        let group = editorArea.activeGroup
        guard group.tabViewItems.indices.contains(group.selectedTabViewItemIndex) else {
            view.window?.performClose(sender)
            return
        }
        group.removeTabViewItem(group.tabViewItems[group.selectedTabViewItemIndex])
    }

    // MARK: - Tabs

    private func tab(for node: LibraryNode, at url: URL) -> NSTabViewItem {
        NSTabViewItem(viewController: TranscriptViewController(fileURL: url, title: node.title))
    }

    /// Selects the tab showing `url` in whichever editor has it, and answers
    /// it with its editor. The active editor stays where the reader is.
    private func selectTab(showing url: URL) -> (EditorGroupViewController, NSTabViewItem)? {
        for group in editorArea.groups {
            guard
                let index = group.tabViewItems.firstIndex(where: {
                    ($0.viewController as? TranscriptViewController)?.fileURL == url
                })
            else { continue }
            group.selectedTabViewItemIndex = index
            return (group, group.tabViewItems[index])
        }
        return nil
    }

    /// The library's node for a transcript, searched from the top.
    private func node(forTranscriptAt url: URL) -> LibraryNode? {
        var pending = library.nodes
        while let node = pending.popLast() {
            if node.transcriptURL == url { return node }
            pending += node.children
        }
        return nil
    }
}

extension MainSplitViewController: SidebarViewControllerDelegate {
    func sidebarViewController(_ sidebar: SidebarViewController, didSelect node: LibraryNode) {
        guard let url = node.transcriptURL, selectTab(showing: url) == nil else { return }
        editorArea.activeGroup.previewTabViewItem = tab(for: node, at: url)
    }

    func sidebarViewController(_ sidebar: SidebarViewController, didOpen node: LibraryNode) {
        guard let url = node.transcriptURL else { return }
        if let (group, item) = selectTab(showing: url) {
            if group.previewTabViewItem === item { group.previewTabViewItem = nil }
            return
        }
        editorArea.activeGroup.addTabViewItem(tab(for: node, at: url))
    }
}

extension MainSplitViewController: EditorAreaViewControllerDelegate {
    func editorArea(_ editorArea: EditorAreaViewController, willClose viewController: NSViewController) {
        (viewController as? TranscriptViewController)?.prepareForRemoval()
    }

    func editorArea(
        _ editorArea: EditorAreaViewController, tabViewItemForDrop draggingInfo: NSDraggingInfo
    ) -> NSTabViewItem? {
        guard
            let url = draggingInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self])?.first as? URL,
            let node = node(forTranscriptAt: url)
        else { return nil }
        return tab(for: node, at: url)
    }
}
