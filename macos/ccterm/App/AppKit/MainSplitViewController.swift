import AppKit
import TranscriptWorkspace

/// The main window's sidebar/detail split: the session library on the left,
/// an Xcode-style editor area — tabs, two editors side by side — on the right.
///
/// Routes between them the way Xcode's navigator does: a transcript already
/// open is selected where it is; otherwise selecting it in the sidebar shows
/// it in the active editor's temporary tab, and double-clicking it opens a tab
/// that stays. Dragged from the sidebar, it opens where it is dropped. Back
/// and forward walk the active editor's history, which knows each tab by its
/// transcript's URL (`NSTabViewItem.identifier`).
///
/// What a transcript's cards open — a diff, a file, a command's output — goes
/// beside the transcript, in the other editor (opened for it when there is
/// only one), as Xcode's assistant does: in its temporary tab, or a tab that
/// stays when the reader double-clicked. The history knows those tabs by
/// their ``ToolDocument/ID``.
///
/// The sidebar never collapses: it is where transcripts are opened from, and
/// the window is always wide enough for it.
@MainActor
final class MainSplitViewController: NSSplitViewController {
    weak var delegate: MainSplitViewControllerDelegate?

    private let library: LibraryStore
    private let sidebarViewController: SidebarViewController
    private let editorArea = EditorAreaViewController()

    /// The transcript last reported to the delegate.
    private var shownTranscript: URL?
    /// Every document opened, for the history to open again.
    private var documents: [ToolDocument.ID: ToolDocument] = [:]

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
        // Xcode's navigator at its narrowest.
        sidebarItem.minimumThickness = 290
        sidebarItem.maximumThickness = 350
        // First-launch width when no autosaved divider position exists,
        // clamped into [290, 350]. Once autosave kicks in this is ignored.
        sidebarItem.preferredThicknessFraction = 0.22
        sidebarItem.canCollapse = false
        sidebarItem.canCollapseFromWindowResize = false
        sidebarItem.titlebarSeparatorStyle = .automatic
        addSplitViewItem(sidebarItem)

        let detailItem = NSSplitViewItem(viewController: editorArea)
        detailItem.minimumThickness = 680
        detailItem.canCollapse = false
        detailItem.titlebarSeparatorStyle = .none
        addSplitViewItem(detailItem)

        splitView.dividerStyle = .thin
        // Persist the user's divider position across launches. Set after both items are added — AppKit
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

    /// Back through the active editor's history — the toolbar's back button.
    @objc func goBack(_ sender: Any?) {
        editorArea.activeGroup.goBack()
    }

    /// Forward through the active editor's history — the toolbar's forward button.
    @objc func goForward(_ sender: Any?) {
        editorArea.activeGroup.goForward()
    }

    // MARK: - Tabs

    /// A tab for the transcript at `url`, known to the history by that URL.
    private func tab(for node: LibraryNode, at url: URL) -> NSTabViewItem {
        let controller = TranscriptViewController(fileURL: url, title: node.title)
        controller.delegate = self
        let item = NSTabViewItem(viewController: controller)
        item.identifier = url
        return item
    }

    /// A tab for `document`, known to the history by its id.
    private func tab(for document: ToolDocument) -> NSTabViewItem {
        let item = NSTabViewItem(viewController: ToolDocumentViewController(document: document))
        item.identifier = document.id
        return item
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

extension MainSplitViewController: TranscriptViewControllerDelegate {
    /// Selects the document where it is already open; otherwise opens it in
    /// the editor beside the transcript's.
    func transcriptViewController(
        _ controller: TranscriptViewController, open document: ToolDocument, pinned: Bool
    ) {
        documents[document.id] = document
        for group in editorArea.groups {
            guard
                let index = group.tabViewItems.firstIndex(where: {
                    ($0.viewController as? ToolDocumentViewController)?.document.id == document.id
                })
            else { continue }
            group.selectedTabViewItemIndex = index
            if pinned, group.previewTabViewItem === group.tabViewItems[index] { group.previewTabViewItem = nil }
            return
        }
        let item = tab(for: document)
        let beside = editorArea.groups.first { group in
            !group.tabViewItems.contains { $0.viewController === controller }
        }
        guard let beside else {
            let group = editorArea.addGroup(with: item)
            if !pinned { group?.previewTabViewItem = item }
            return
        }
        if pinned {
            beside.addTabViewItem(item)
        } else {
            beside.previewTabViewItem = item
        }
    }
}

extension MainSplitViewController: NSToolbarItemValidation {
    /// Back and forward are enabled while the active editor has somewhere to go.
    /// Asked by the toolbar as it validates, after every event.
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.action {
        case #selector(goBack(_:)): editorArea.activeGroup.canGoBack
        case #selector(goForward(_:)): editorArea.activeGroup.canGoForward
        default: true
        }
    }
}

extension MainSplitViewController: EditorAreaViewControllerDelegate {
    /// Tells the window when the reader is in another transcript, or in none.
    func editorArea(_ editorArea: EditorAreaViewController, didActivate viewController: NSViewController?) {
        let transcript =
            (viewController as? TranscriptViewController)?.fileURL
            ?? (viewController as? ToolDocumentViewController)?.transcriptURL
        guard transcript != shownTranscript else { return }
        shownTranscript = transcript
        delegate?.mainSplitViewController(self, didShowTranscriptAt: transcript)
    }

    /// A tab again for a transcript the history goes back to, while the library
    /// still has it — or for a document opened before.
    func editorArea(
        _ editorArea: EditorAreaViewController, tabViewItemWithIdentifier identifier: Any
    ) -> NSTabViewItem? {
        if let id = identifier as? ToolDocument.ID {
            return documents[id].map(tab(for:))
        }
        guard let url = identifier as? URL, let node = library.path(toTranscriptAt: url).last else { return nil }
        return tab(for: node, at: url)
    }

    func editorArea(_ editorArea: EditorAreaViewController, willClose viewController: NSViewController) {
        (viewController as? TranscriptViewController)?.prepareForRemoval()
    }

    func editorArea(
        _ editorArea: EditorAreaViewController, tabViewItemForDrop draggingInfo: NSDraggingInfo
    ) -> NSTabViewItem? {
        guard
            let url = draggingInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self])?.first as? URL,
            let node = library.path(toTranscriptAt: url).last
        else { return nil }
        return tab(for: node, at: url)
    }
}
