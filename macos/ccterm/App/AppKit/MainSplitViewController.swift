import AppKit
import Combine
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
/// The sidebar never collapses: it is where transcripts are opened from, and
/// the window is always wide enough for it.
@MainActor
final class MainSplitViewController: NSSplitViewController {
    weak var delegate: MainSplitViewControllerDelegate?

    private let library: LibraryStore
    private let sidebarViewController: SidebarViewController

    /// The tabs. It answers the window's tab commands itself — back, forward,
    /// Close Tab — and the toolbar aims at it.
    let editorArea = EditorAreaViewController()

    /// The transcript last reported to the delegate.
    private var shownTranscript: URL?

    init(library: LibraryStore) {
        self.library = library
        sidebarViewController = SidebarViewController(
            nodes: library.$isLoaded.combineLatest(library.$nodes) { isLoaded, nodes in isLoaded ? nodes : nil }
                .eraseToAnyPublisher())
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

    /// A tab command sent to nil — ⌘W — reaches the editor area from the
    /// sidebar too, not only from inside a tab.
    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        Self.areaCommands.contains(action) ? editorArea : super.supplementalTarget(forAction: action, sender: sender)
    }

    private static let areaCommands: Set<Selector> = [
        #selector(EditorAreaViewController.goBack(_:)), #selector(EditorAreaViewController.goForward(_:)),
        #selector(EditorAreaViewController.closeTab(_:)),
    ]

    // MARK: - Tabs

    /// A tab for the transcript at `url`, known to the history by that URL.
    private func tab(for node: LibraryNode, at url: URL) -> NSTabViewItem {
        let transcript = TranscriptViewController(fileURL: url, title: node.title) { [library] in
            try await library.transcript(at: $0)
        }
        let item = NSTabViewItem(viewController: transcript)
        item.identifier = url
        return item
    }
}

extension MainSplitViewController: SidebarViewControllerDelegate {
    func sidebarViewController(_ sidebar: SidebarViewController, didSelect node: LibraryNode) {
        guard let url = node.transcriptURL, !editorArea.selectTabViewItem(withIdentifier: url) else { return }
        editorArea.activeGroup.previewTabViewItem = tab(for: node, at: url)
    }

    func sidebarViewController(_ sidebar: SidebarViewController, didOpen node: LibraryNode) {
        guard let url = node.transcriptURL else { return }
        guard !editorArea.selectTabViewItem(withIdentifier: url, pinning: true) else { return }
        editorArea.activeGroup.addTabViewItem(tab(for: node, at: url))
    }
}

extension MainSplitViewController: EditorAreaViewControllerDelegate {
    /// Tells the window when the reader is in another transcript, or in none.
    func editorArea(_ editorArea: EditorAreaViewController, didActivate viewController: NSViewController?) {
        let transcript = (viewController as? TranscriptViewController)?.fileURL
        guard transcript != shownTranscript else { return }
        shownTranscript = transcript
        delegate?.mainSplitViewController(self, didShowTranscriptAt: transcript)
    }

    /// A tab again for a transcript the history goes back to, while the library
    /// still has it.
    func editorArea(
        _ editorArea: EditorAreaViewController, tabViewItemWithIdentifier identifier: Any
    ) -> NSTabViewItem? {
        guard let url = identifier as? URL, let node = library.path(toTranscriptAt: url).last else { return nil }
        return tab(for: node, at: url)
    }

    func editorArea(_ editorArea: EditorAreaViewController, willClose viewController: NSViewController) {
        (viewController as? TranscriptViewController)?.prepareForRemoval()
    }

    /// A transcript dragged from the sidebar, by its URL — the tab comes from
    /// `editorArea(_:tabViewItemWithIdentifier:)`, as the history's do.
    func editorArea(_ editorArea: EditorAreaViewController, identifierForDrop draggingInfo: NSDraggingInfo) -> Any? {
        draggingInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self])?.first as? URL
    }
}
