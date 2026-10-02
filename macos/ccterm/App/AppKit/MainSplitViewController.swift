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
/// **New tabs** (design 08 *Tabs and the +*): every editor's bar ends in a +, and
/// ⌘T opens a New tab — a `SessionTabViewController` as a draft — after the
/// active one, or selects the group's New tab that nobody has touched. With no
/// tab at all the area shows a New view of its own, no bar; sending from it
/// moves that same controller into the first tab. A New tab becomes its
/// session's at Send (`transcriptTab(_:didStartSessionAt:)`): the item is
/// re-identified in place, so nothing about the tab changes but what it is.
/// The words of a New tab that closes are kept for the next one made.
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

    /// The words of the New tab closed last, for the next New tab made.
    private var closedDraftText = ""
    /// The sidebar's projects, most recent first: where a New tab starts when
    /// nothing else says.
    private var recentFolders: [URL] = []
    /// Each live session's activity, from the store.
    private var activities: [URL: SessionState.Activity] = [:]
    /// One mark per session shown in a tab, kept so an animating mark is the
    /// same view for as long as its state is.
    private var marks: [URL: ActivityMarkView] = [:]
    private var subscriptions: Set<AnyCancellable> = []

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
        editorArea.showsNewTabButton = true
        context.recentFolders
            .sink { [weak self] in self?.recentFolders = $0 }
            .store(in: &subscriptions)
        // With no tab the area is a New tab without its tab.
        editorArea.emptyViewController = makeNewSession()
        sessions.$activities
            .sink { [weak self] in self?.activitiesDidChange($0) }
            .store(in: &subscriptions)
    }

    /// A tab command sent to nil — ⌘W — reaches the editor area from the
    /// sidebar too, not only from inside a tab.
    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        // ⌘. stops the active session tab's turn from anywhere in the window.
        if action == #selector(SessionTabViewController.stopResponding(_:)) {
            return editorArea.activeViewController as? SessionTabViewController
        }
        return Self.areaCommands.contains(action)
            ? editorArea : super.supplementalTarget(forAction: action, sender: sender)
    }

    private static let areaCommands: Set<Selector> = [
        #selector(EditorAreaViewController.goBack(_:)), #selector(EditorAreaViewController.goForward(_:)),
        #selector(EditorAreaViewController.closeTab(_:)), #selector(EditorAreaViewController.newTab(_:)),
    ]

    // MARK: - New tabs

    /// File › New Tab: in the active editor, as the + of its bar does.
    func newTab() {
        editorArea.newTab(nil)
    }

    /// A New view for the area to show while it has no tab, starting in the
    /// default folder with the words of the New tab closed last.
    private func makeNewSession() -> NSViewController {
        TranscriptTab.makeNewSession(
            folder: defaultFolder(), text: takeClosedDraftText(), context: context, delegate: self)
    }

    private func takeClosedDraftText() -> String {
        defer { closedDraftText = "" }
        return closedDraftText
    }

    /// Where a New tab starts: the folder of the session tab that is active —
    /// a New tab's choice, or the project its transcript is listed under —
    /// else the most recent project.
    private func defaultFolder() -> URL? {
        let group = editorArea.activeGroup
        if group.tabViewItems.indices.contains(group.selectedTabViewItemIndex) {
            let item = group.tabViewItems[group.selectedTabViewItemIndex]
            if let tab = item.viewController as? SessionTabViewController, let folder = tab.folder { return folder }
            if let url = TranscriptTab(identifier: item.identifier)?.transcriptURL,
                let project = library.path(toTranscriptAt: url).first
            {
                return URL(fileURLWithPath: project.id, isDirectory: true)
            }
        }
        return recentFolders.first
    }

    /// Makes a New view for the empty area again — the one it showed became a
    /// tab, or the tabs ran out and the words of the last New tab go with it.
    private func renewEmptyNewSession() {
        let previous = editorArea.emptyViewController
        editorArea.emptyViewController = makeNewSession()
        if let previous { TranscriptTab.prepareForRemoval(previous) }
    }

    /// Tells the window the reader is in `transcript`, unless it already knows.
    private func show(transcript: URL?) {
        guard transcript != shownTranscript else { return }
        shownTranscript = transcript
        delegate?.mainSplitViewController(self, didShowTranscriptAt: transcript)
    }

    /// The tabs' marks: a session's activity in the slot its close button uses —
    /// nothing while idle or at rest, which the sidebar shows and the tab bar
    /// has no room for.
    private func activitiesDidChange(_ activities: [URL: SessionState.Activity]) {
        self.activities = activities
        marks = marks.filter { activities[$0.key] != nil }
        editorArea.reloadIndicators()
    }

}

extension MainSplitViewController: TranscriptTabDelegate {
    /// The New tab is its session's from here: the item changes what it is, in
    /// place — or, for the New view the empty area shows, becomes the first tab
    /// with the same controller in it — before this returns, so the window,
    /// told below, never sees a tab that is neither. The active controller is
    /// the same object, so the editor area reports no activation of its own.
    func transcriptTab(_ source: NSViewController, didStartSessionAt url: URL) {
        let identifier = TranscriptTab.transcript(url)
        if let item = editorArea.groups.lazy.flatMap(\.tabViewItems).first(where: { $0.viewController === source }) {
            item.identifier = identifier
        } else if source === editorArea.emptyViewController {
            let item = NSTabViewItem(viewController: source)
            item.identifier = identifier
            editorArea.open(item, pinned: true)
            renewEmptyNewSession()
        } else {
            appLog(.warning, "MainSplitViewController", "a session started in a tab that is not open")
            return
        }
        show(transcript: url)
        sidebarViewController.select(transcriptAt: url)
    }

    /// A launch stopped before it began: the tab is a New tab again.
    func transcriptTabDidReturnToDraft(_ source: NSViewController) {
        guard let item = editorArea.groups.lazy.flatMap(\.tabViewItems).first(where: { $0.viewController === source })
        else { return }
        item.identifier = TranscriptTab.newSession(UUID())
        show(transcript: nil)
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
        show(transcript: transcript)
        // The tabs ran out: the area is a New view again, with the words of the
        // New tab closed last.
        if viewController == nil { renewEmptyNewSession() }
    }

    /// ⌘T or a + on a bar: the group's New tab nobody has touched, selected;
    /// else a New tab after the active one, pinned, in its folder. With no tab
    /// the New view is already there.
    func editorArea(_ editorArea: EditorAreaViewController, didRequestNewTabIn group: EditorGroupViewController) {
        guard !group.tabViewItems.isEmpty else {
            (editorArea.emptyViewController as? SessionTabViewController)?.focusComposer()
            return
        }
        if let index = group.tabViewItems.firstIndex(where: {
            $0.viewController.map(TranscriptTab.isUntouchedDraft) ?? false
        }) {
            group.selectedTabViewItemIndex = index
            return
        }
        let item = TranscriptTab.makeNewSessionItem(
            folder: defaultFolder(), text: takeClosedDraftText(), context: context, delegate: self)
        group.insertTabViewItem(item, at: group.selectedTabViewItemIndex + 1)
    }

    /// A live session's mark in its tab: the running arc, coral, red — and
    /// nothing while it is idle.
    func editorArea(_ editorArea: EditorAreaViewController, indicatorViewFor tabViewItem: NSTabViewItem) -> NSView? {
        guard case .transcript(let url)? = TranscriptTab(identifier: tabViewItem.identifier),
            let activity = activities[url], activity != .idle
        else { return nil }
        let mark = marks[url] ?? ActivityMarkView()
        marks[url] = mark
        mark.activity = activity
        return mark
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

    /// A New tab closing leaves its words for the next one.
    func editorArea(_ editorArea: EditorAreaViewController, willClose viewController: NSViewController) {
        if let words = TranscriptTab.draftText(of: viewController) { closedDraftText = words }
        TranscriptTab.prepareForRemoval(viewController)
    }

    /// A transcript dragged from the sidebar, by its URL — the tab comes from
    /// `editorArea(_:tabViewItemWithIdentifier:)`, as the history's do.
    func editorArea(_ editorArea: EditorAreaViewController, identifierForDrop draggingInfo: NSDraggingInfo) -> Any? {
        (draggingInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self])?.first as? URL)
            .map { TranscriptTab.transcript($0) }
    }
}
