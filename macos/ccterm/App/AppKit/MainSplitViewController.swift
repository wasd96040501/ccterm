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
        sidebarViewController = SidebarViewController(nodes: library.$nodes.eraseToAnyPublisher())
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
        transcript.delegate = self
        let item = NSTabViewItem(viewController: transcript)
        item.identifier = url
        return item
    }

    /// A tab for a document beside a transcript, known to the history by its
    /// reference. `document` is what the reader just opened; a tab made again
    /// from history reads it from the transcript.
    private func tab(for reference: DocumentReference, document: Document? = nil) -> NSTabViewItem {
        let controller = DocumentViewController(
            reference: reference, document: document,
            loadTranscript: { [library] in try await library.transcript(at: $0) }
        ) { [library, weak self] url, title in
            let conversation = TranscriptViewController(fileURL: url, title: title) {
                try await library.transcript(at: $0)
            }
            conversation.delegate = self
            return conversation
        }
        controller.delegate = self
        let item = NSTabViewItem(viewController: controller)
        item.identifier = reference
        return item
    }

    /// The editor whose tab holds `viewController`, or one of its ancestors —
    /// a subagent's conversation sits inside its document's tab.
    private func group(containing viewController: NSViewController) -> EditorGroupViewController? {
        var candidate: NSViewController? = viewController
        while let current = candidate {
            if let group = editorArea.groups.first(where: { $0.tabViewItems.contains { $0.viewController === current } }
            ) {
                return group
            }
            candidate = current.parent
        }
        return nil
    }

    /// The open transcript tab for `url`, and the editor it is in.
    private func transcriptTab(for url: URL) -> TranscriptViewController? {
        editorArea.groups.lazy.flatMap(\.tabViewItems)
            .compactMap { $0.viewController as? TranscriptViewController }
            .first { $0.fileURL == url }
    }
}

extension MainSplitViewController: TranscriptViewControllerDelegate {
    /// Opens a document in the *other* editor as its temporary tab — splitting
    /// the area on the first — so clicking down a list replaces one tab where
    /// it stands; `pinned` opens it in a tab that stays. A document already
    /// open is brought forward where it is.
    func transcriptViewController(_ transcript: TranscriptViewController, open document: Document, pinned: Bool) {
        let reference = document.reference
        guard !editorArea.selectTabViewItem(withIdentifier: reference, pinning: pinned) else { return }
        let item = tab(for: reference, document: document)
        let source = group(containing: transcript)
        if let other = editorArea.groups.first(where: { $0 !== source }) {
            if pinned { other.addTabViewItem(item) } else { other.previewTabViewItem = item }
        } else if let other = editorArea.addGroup(with: item), !pinned {
            other.previewTabViewItem = item
        }
    }
}

extension MainSplitViewController: DocumentViewControllerDelegate {
    /// Brings the transcript's tab forward and the item back into view in it.
    func documentViewController(_ document: DocumentViewController, showInTranscript reference: DocumentReference) {
        guard let transcript = transcriptTab(for: reference.transcriptURL) else {
            appLog(
                .info, "MainSplitViewController",
                "Show in Transcript: \(reference.transcriptURL.lastPathComponent) is not open")
            return
        }
        editorArea.selectTabViewItem(withIdentifier: reference.transcriptURL)
        transcript.reveal(reference.id, select: true)
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
        if let reference = identifier as? DocumentReference { return tab(for: reference) }
        guard let url = identifier as? URL, let node = library.path(toTranscriptAt: url).last else { return nil }
        return tab(for: node, at: url)
    }

    func editorArea(_ editorArea: EditorAreaViewController, willClose viewController: NSViewController) {
        // A document's body may be a subagent's conversation, made here.
        for controller in [viewController] + viewController.children {
            (controller as? TranscriptViewController)?.prepareForRemoval()
            (controller as? DocumentViewController)?.prepareForRemoval()
        }
    }

    /// A transcript dragged from the sidebar, by its URL — the tab comes from
    /// `editorArea(_:tabViewItemWithIdentifier:)`, as the history's do.
    func editorArea(_ editorArea: EditorAreaViewController, identifierForDrop draggingInfo: NSDraggingInfo) -> Any? {
        draggingInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self])?.first as? URL
    }
}
