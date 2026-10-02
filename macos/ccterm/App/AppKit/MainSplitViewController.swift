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
/// `TranscriptTab` (`NSTabViewItem.identifier`).
///
/// The sidebar never collapses: it is where transcripts are opened from, and
/// the window is always wide enough for it.
@MainActor
final class MainSplitViewController: NSSplitViewController {
    weak var delegate: MainSplitViewControllerDelegate?

    private let library: LibraryStore
    private let context: TranscriptTab.Context
    private var sessions: SessionStore { context.sessions }
    private let sidebarViewController: SidebarViewController

    /// The tabs. It answers the window's tab commands itself — back, forward,
    /// Close Tab — and the toolbar aims at it.
    let editorArea = EditorAreaViewController()

    /// The transcript last reported to the delegate.
    private var shownTranscript: URL?

    init(library: LibraryStore, context: TranscriptTab.Context) {
        self.library = library
        self.context = context
        let sessions = context.sessions
        sidebarViewController = SidebarViewController(
            nodes: library.$isLoaded.combineLatest(library.$nodes) { isLoaded, nodes in isLoaded ? nodes : nil }
                .eraseToAnyPublisher(),
            activities: sessions.$activities.eraseToAnyPublisher())
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

    // MARK: - New tabs

    // TODO(fill E): the New tab (design 08 *Tabs and the +*):
    // - `editorArea.showsNewTabButton = true`; `editorArea.emptyViewController`
    //   = `TranscriptTab.makeNewSession(...)`, made again whenever the tabs run out;
    // - ⌘T / + (`editorArea(_:didRequestNewTabIn:)`): the group's untouched New tab
    //   if it has one (`TranscriptTab.isUntouchedDraft`), else a New tab after the
    //   active one, in the active session tab's folder or the most recent project,
    //   with the words of the last New tab closed (`TranscriptTab.draftText`, kept
    //   in `willClose`);
    // - tab marks: `editorArea(_:indicatorViewFor:)` from `sessions.$activities`,
    //   one cached `ActivityMarkView` per transcript URL, `reloadIndicators()` on change.

    // MARK: - Sessions

    /// File › New Session…: asks for the folder to run it in, starts it, and
    /// opens its tab, pinned, ready to type in.
    func newSession() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose the folder Claude will work in.")
        panel.prompt = String(localized: "Start Session")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            self?.startSession(in: folder, window: window)
        }
    }

    private func startSession(in folder: URL, window: NSWindow) {
        Task {
            do {
                let url = try await sessions.start(in: folder)
                editorArea.open(
                    TranscriptTab.makeItem(
                        .transcript(url), title: String(localized: "New Session"), context: context,
                        delegate: self),
                    pinned: true)
            } catch {
                appLog(.error, "MainSplitViewController", "New Session in \(folder.path) failed — \(error)")
                _ = await NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }
}

extension MainSplitViewController: TranscriptTabDelegate {
    func transcriptTab(_ source: NSViewController, didStartSessionAt url: URL) {
        // TODO(fill E): re-identify the item (or move `source` from the empty
        // area into the first tab), then what `editorArea(_:didActivate:)` does.
    }

    func transcriptTabDidReturnToDraft(_ source: NSViewController) {
        // TODO(fill E): the item is a `.newSession` again.
    }

    /// Opens a tab beside its source — in the *other* editor as its temporary
    /// tab, splitting the area on the first — so clicking down a list replaces
    /// one tab where it stands; `pinned` opens it in a tab that stays. A tab
    /// already open is brought forward where it is. Either way the focus goes
    /// to it, so the window's commands (⌘W) aim at what the reader just opened.
    func transcriptTab(
        _ source: NSViewController, didRequestOpen tab: TranscriptTab, pinned: Bool,
        makeItem: () -> NSTabViewItem
    ) {
        if !editorArea.selectTabViewItem(withIdentifier: tab, pinning: pinned) {
            editorArea.open(makeItem(), pinned: pinned, beside: source)
        }
        guard let item = editorArea.tabViewItem(withIdentifier: tab) else { return }
        TranscriptTab.focus(item)
    }

    /// Brings the transcript's tab forward and the item back into view in it.
    func transcriptTab(_ source: NSViewController, didRequestReveal itemID: String, inTranscriptAt url: URL) {
        guard let item = editorArea.tabViewItem(withIdentifier: TranscriptTab.transcript(url)) else {
            appLog(.info, "MainSplitViewController", "Show in Transcript: \(url.lastPathComponent) is not open")
            return
        }
        editorArea.selectTabViewItem(withIdentifier: TranscriptTab.transcript(url))
        TranscriptTab.reveal(itemID, in: item)
    }
}

extension MainSplitViewController: SidebarViewControllerDelegate {
    func sidebarViewController(_ sidebar: SidebarViewController, didSelect node: LibraryNode) {
        guard let url = node.transcriptURL,
            !editorArea.selectTabViewItem(withIdentifier: TranscriptTab.transcript(url))
        else { return }
        editorArea.open(
            TranscriptTab.makeItem(.transcript(url), title: node.title, context: context, delegate: self),
            pinned: false)
    }

    /// End Session: the session's CLI exits; its transcript stays.
    func sidebarViewController(_ sidebar: SidebarViewController, didRequestEndOf node: LibraryNode) {
        guard let url = node.transcriptURL else { return }
        Task { await sessions.end(at: url) }
    }

    func sidebarViewController(_ sidebar: SidebarViewController, didOpen node: LibraryNode) {
        guard let url = node.transcriptURL else { return }
        guard !editorArea.selectTabViewItem(withIdentifier: TranscriptTab.transcript(url), pinning: true) else {
            return
        }
        editorArea.open(
            TranscriptTab.makeItem(.transcript(url), title: node.title, context: context, delegate: self),
            pinned: true)
    }
}

extension MainSplitViewController: EditorAreaViewControllerDelegate {
    /// Tells the window when the reader is in another transcript, or in none.
    /// A document is in its transcript's session.
    func editorArea(_ editorArea: EditorAreaViewController, didActivate viewController: NSViewController?) {
        let transcript = viewController.flatMap { viewController in
            editorArea.activeGroup.tabViewItems.first { $0.viewController === viewController }
        }.flatMap { TranscriptTab(identifier: $0.identifier)?.transcriptURL }
        guard transcript != shownTranscript else { return }
        shownTranscript = transcript
        delegate?.mainSplitViewController(self, didShowTranscriptAt: transcript)
    }

    /// A tab again for a transcript the history goes back to, while the library
    /// still has it.
    func editorArea(
        _ editorArea: EditorAreaViewController, tabViewItemWithIdentifier identifier: Any
    ) -> NSTabViewItem? {
        switch TranscriptTab(identifier: identifier) {
        case .document(let reference)?:
            return TranscriptTab.makeItem(.document(reference), title: "", context: context, delegate: self)
        case .transcript(let url)?:
            guard let node = library.path(toTranscriptAt: url).last else { return nil }
            return TranscriptTab.makeItem(.transcript(url), title: node.title, context: context, delegate: self)
        case .newSession?, nil:
            // A New tab's draft is gone once it closed.
            return nil
        }
    }

    func editorArea(_ editorArea: EditorAreaViewController, willClose viewController: NSViewController) {
        TranscriptTab.prepareForRemoval(viewController)
    }

    /// A transcript dragged from the sidebar, by its URL — the tab comes from
    /// `editorArea(_:tabViewItemWithIdentifier:)`, as the history's do.
    func editorArea(_ editorArea: EditorAreaViewController, identifierForDrop draggingInfo: NSDraggingInfo) -> Any? {
        (draggingInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self])?.first as? URL)
            .map { TranscriptTab.transcript($0) }
    }
}
