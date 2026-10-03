import AgentSDK
import AppKit
import Combine
import Components
import TranscriptWorkspace

/// Window controller for the AppKit-rooted main window. The window is
/// created in `applicationWillFinishLaunching` rather than declared as a
/// SwiftUI `Window` scene, so everything mounted in it runs in AppKit's
/// source phase without SwiftUI commit-pass interleaving.
///
/// Owns the toolbar, laid out as Xcode's over the editors: back and forward
/// through the active editor's history, then the project the reader is in and
/// its git branch. Nothing sits over the sidebar, which never collapses, so
/// there is no sidebar button either.
@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate {
    private let library: LibraryStore
    private let git: GitService
    private let splitController: MainSplitViewController
    private let titleView = MainWindowTitleView()

    /// The task following the shown transcript's branch.
    private var branchTask: Task<Void, Never>?
    /// The transcript shown, and whether the library had its project when its
    /// title was set — a session just started isn't listed until the CLI writes
    /// its transcript, so the title waits for the library's next read.
    private var shownTranscript: URL?
    private var titleHasProject = false
    private var libraryObservation: AnyCancellable?
    /// Waiting to show the window; see `showWindow(whenLoadedWithin:)`.
    private var pendingShow: AnyCancellable?

    init(library: LibraryStore, context: TranscriptTab.Context, git: GitService) {
        self.library = library
        self.git = git
        splitController = MainSplitViewController(library: library, context: context)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "ccterm"
        window.titlebarAppearsTransparent = true
        // The toolbar's title item shows it instead (`MainWindowTitleView`);
        // `title` still names the window in the Window menu and Mission Control.
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 970, height: 540)  // the sidebar's 290 beside the editors' 680
        window.contentViewController = splitController

        super.init(window: window)
        // NSWindowController defaults `shouldCascadeWindows` to true,
        // which moves the window on `showWindow(_:)` based on the last
        // displayed window's origin — racing with the autosaved frame.
        // Disable so the saved frame is the only source of truth.
        shouldCascadeWindows = false
        // Centred until a saved frame replaces it: persisting the frame is the
        // composition root's (`windowFrameAutosaveName`), which applies the
        // saved one as it is set.
        window.center()
        splitController.delegate = self
        installToolbar()
        libraryObservation = library.$nodes.dropFirst().sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let url = self.shownTranscript, !self.titleHasProject else { return }
                self.showTitle(of: url)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Shows the window once the sidebar has its tree — the library's first
    /// read — so it doesn't open on an empty sidebar; but no later than
    /// `deadline`, past which it opens with the sidebar still loading.
    func showWindow(whenLoadedWithin deadline: DispatchQueue.SchedulerTimeType.Stride) {
        let clock = ContinuousClock()
        let start = clock.now
        pendingShow = library.$isLoaded.first { $0 }
            .timeout(deadline, scheduler: DispatchQueue.main)
            // A turn later, so every sink of the first read — the sidebar's —
            // has run before the window draws.
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        let state = self.library.isLoaded ? "loaded" : "still loading"
                        appLog(.info, "MainWindowController", "shown \(state) after \(clock.now - start)")
                        self.showWindow(nil)
                    }
                }, receiveValue: { _ in })
    }

    /// Shows the window now, whatever `showWindow(whenLoadedWithin:)` was
    /// waiting for.
    override func showWindow(_ sender: Any?) {
        pendingShow = nil
        super.showWindow(sender)
    }

    /// File › New Tab, in this window's editors.
    func newTab() {
        splitController.newTab()
    }

    private func installToolbar() {
        let toolbar = NSToolbar(identifier: "ccterm.main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = false
        window?.toolbar = toolbar
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // `.sidebarTrackingSeparator` is system-provided: it keeps the items
        // after it over the editors, whatever the sidebar's width.
        [.sidebarTrackingSeparator, .navigation, .projectTitle, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .navigation: navigationItem()
        case .projectTitle: titleItem()
        default: nil
        }
    }

    /// Back and forward as one control, as Xcode's and Finder's: a momentary
    /// segmented group, each segment a subitem with its own action, aimed at the
    /// editor area and validated by it. Navigational, so AppKit keeps it at the leading
    /// edge of the title area.
    private func navigationItem() -> NSToolbarItem {
        let back = String(localized: "Back")
        let forward = String(localized: "Forward")
        let group = NSToolbarItemGroup(
            itemIdentifier: .navigation,
            images: [
                NSImage(systemSymbolName: "chevron.left", accessibilityDescription: back),
                NSImage(systemSymbolName: "chevron.right", accessibilityDescription: forward),
            ].compactMap { $0 },
            selectionMode: .momentary, labels: [back, forward], target: splitController.editorArea, action: nil)
        for (subitem, action) in zip(
            group.subitems,
            [#selector(EditorAreaViewController.goBack(_:)), #selector(EditorAreaViewController.goForward(_:))])
        {
            subitem.target = splitController.editorArea
            subitem.action = action
        }
        group.isNavigational = true
        return group
    }

    /// The title is text, not a control: no bezel around it.
    private func titleItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .projectTitle)
        item.view = titleView
        item.isBordered = false
        return item
    }
}

extension MainWindowController: MainSplitViewControllerDelegate {
    /// Names the transcript's project — its folder in the sidebar — under its
    /// session's branch, and follows the branch until another transcript is
    /// shown. Name and branch change together, on the branch's first answer, so
    /// a name never stands over another project's branch; with no transcript,
    /// the title goes at once.
    func mainSplitViewController(_ split: MainSplitViewController, didShowTranscriptAt url: URL?) {
        shownTranscript = url
        guard let url else {
            branchTask?.cancel()
            branchTask = nil
            titleHasProject = false
            show(project: nil, branch: nil)
            return
        }
        showTitle(of: url)
    }

    private func showTitle(of url: URL) {
        branchTask?.cancel()
        branchTask = nil
        guard let project = library.path(toTranscriptAt: url).first else {
            titleHasProject = false
            show(project: nil, branch: nil)
            return
        }
        titleHasProject = true
        // A worktree session says so under its project, in place of the branch.
        let worktree = library.path(toTranscriptAt: url).last?.worktreeBranch.map {
            SessionTabTitle.worktreeSubtitle(branch: $0)
        }
        if let worktree {
            show(project: project.title, branch: worktree)
            return
        }
        branchTask = Task { [weak self, library, git] in
            // The live branch of the folder the session ran in (a worktree's
            // own); once that is no repository — a worktree removed — the
            // branch the transcript last recorded.
            let metadata = await library.metadata(ofTranscriptAt: url)
            var branches: AsyncStream<String?>?
            if let cwd = metadata?.cwd { branches = await git.branchUpdates(at: cwd) }
            guard let branches else {
                guard !Task.isCancelled else { return }
                // The CLI records a detached HEAD as "HEAD".
                self?.show(project: project.title, branch: metadata?.gitBranch.flatMap { $0 == "HEAD" ? nil : $0 })
                return
            }
            for await branch in branches {
                guard !Task.isCancelled else { return }
                self?.show(project: project.title, branch: branch)
            }
        }
    }

    /// The title names the window in the Window menu and Mission Control too.
    private func show(project: String?, branch: String?) {
        window?.title = project ?? "ccterm"
        titleView.title = project
        titleView.subtitle = branch
    }
}

extension NSToolbarItem.Identifier {
    fileprivate static let navigation = NSToolbarItem.Identifier("ccterm.main.navigation")
    fileprivate static let projectTitle = NSToolbarItem.Identifier("ccterm.main.projectTitle")
}
