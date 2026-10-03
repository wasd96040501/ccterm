import AppKit
import Components
import DisplayModels
import TranscriptWorkspace

/// The main window (design/transcript, *Playground — a window with no tabs
/// opens on the New view*: `preview-live.js`'s window, `preview-live.css`
/// `.lv-win`), each scenario the sheet's buttons switch between: the sidebar
/// beside the editor area, its tabs, a session's transcript with the composer
/// floating over it, or the New view. All of it real — the sidebar, the
/// editor area and its tab bar (`TranscriptWorkspace`), the transcript
/// (`TranscriptKit`) with the package's row views, the composer and its dock,
/// the New view — inside the design's window, its title the app's
/// `MainWindowTitleView` saying what the app's toolbar would.
enum PlaygroundSpecimen {
    static func section() -> DesignPageViewController.Section {
        DesignPageViewController.Section(
            title: "Main window",
            note:
                "The session library beside the editor area. A transcript opens in a tab; a tab's bar ends in "
                + "a +, and a live session's tab carries its mark where its close button goes. A session's "
                + "composer floats 16 over the tab's bottom edge, 720 wide at most, the transcript fading out "
                + "under it; a window with no tabs is a New view, its composer a third of the way down. The title "
                + "names the project of the transcript in front and its branch — nothing over a New view.",
            specimens: Scene.allCases.map(window))
    }

    private static func window(_ scene: Scene) -> DesignPageViewController.Specimen {
        let content = MainWindowContent(scene)
        let title = scene.title
        let frame = WindowFrame(
            content: content, contentSize: Host.mainWindow,
            chrome: .titled(title: title?.project, subtitle: title?.branch))
        return .init(
            title: scene.caption, view: frame, width: frame.size.width, height: frame.size.height, isWindow: true)
    }

    // MARK: - Scenes

    /// The sheet's scenario buttons, in its order.
    enum Scene: CaseIterable {
        case noTabs, newTab, responding, waiting, atRest, failed, split

        var caption: String {
            switch self {
            case .noTabs: "No tabs — the window opens on the New view"
            case .newTab: "A New tab beside a session"
            case .responding: "Responding — the turn's work as it happens, Stop in the composer"
            case .waiting: "Waiting for you — the approval card, the coral status and marks"
            case .atRest: "At rest — the session resumes when you send"
            case .failed: "Failed — the reason at the composer's top, the red mark"
            case .split: "Split — two editors, a New tab in the focused one"
            }
        }

        /// What the app's toolbar names: the project and branch of the
        /// transcript in front; a New view or New tab is in none.
        var title: (project: String, branch: String)? {
            switch self {
            case .responding, .waiting, .atRest, .failed: ("ccterm", "quiet-otter · worktree")
            case .noTabs, .newTab, .split: nil
            }
        }

        /// The session in front's activity: the sidebar's mark and its tab's.
        var activity: SidebarActivity? {
            switch self {
            case .responding: .responding
            case .waiting: .needsInput
            case .failed: .failed(message: "Claude quit unexpectedly")
            case .noTabs, .newTab, .atRest, .split: nil
            }
        }
    }

    // MARK: - Sessions

    /// `SEED.rest()`: a turn made and settled.
    static let rowGap = SidebarSpecimen.url("Row gap and tool rows")
    /// `SEED.notes()`, in the other project.
    static let tabBar = SidebarSpecimen.url("Tab bar accessory")

    private static let transcriptView = "TranscriptView.swift"
    private static let kitFolder = "macos/TranscriptKit/Sources/TranscriptKit"

    private static var settled: [PlaygroundEntry] {
        typealias R = RowsSpecimen
        let items = [
            R.line(
                .search, text: StyledText("rowSpacing", style: .code), detail: "in macos/TranscriptKit",
                meta: StyledText("4 files")),
            R.line(
                .read, text: StyledText(transcriptView, style: .noun(opens: nil)), detail: kitFolder,
                meta: StyledText("lines 300–325")),
            R.line(
                .change, text: StyledText(transcriptView, style: .noun(opens: nil)), detail: kitFolder,
                meta: StyledText.diffStat(added: 4, removed: 2)),
            R.line(
                .command, text: StyledText("Run the TranscriptView tests"),
                detail: "swift test --package-path macos/TranscriptKit --filter TranscriptViewTests",
                meta: StyledText("21s")),
        ]
        let line = R.line(
            .change,
            text: StyledText("Edited ") + R.file(transcriptView) + StyledText(", ran a command, searched for ")
                + StyledText("rowSpacing", style: .code) + StyledText(", and 1 more"),
            meta: StyledText.diffStat(added: 4, removed: 2) + StyledText("  31s"))
        return [
            .prompt("The rows feel cramped in a narrow split. Make the gap between transcript rows configurable."),
            .run(id: "run1", line: line, items: items, waiting: nil),
            .reply("Done — `TranscriptView.rowSpacing` is public and defaults to 14; the tests pass."),
        ]
    }

    /// The scripted turn (`startTurnBody`) up to where the scene stops it.
    private static func turn(_ scene: Scene) -> [PlaygroundEntry] {
        typealias R = RowsSpecimen
        let runRow = "RunRowView.swift"
        let folder = "macos/ccterm/Content/Transcript"
        let opening: [PlaygroundEntry] = [
            .prompt("Make the summary 12 pt and rebuild."),
            .reply("I'll look at how the run row sets its summary first."),
        ]
        switch scene {
        case .responding:
            let reading = R.line(.read, .running, text: StyledText("Reading ") + R.file(runRow))
            return opening + [.run(id: "run2", line: reading, items: [reading], waiting: nil)]
        case .waiting:
            let read = R.line(
                .read, text: StyledText(runRow, style: .noun(opens: nil)), detail: folder,
                meta: StyledText("lines 1–96"))
            let edit = R.line(
                .change, .waiting, text: StyledText(runRow, style: .noun(opens: nil)), detail: folder,
                meta: StyledText("Needs approval"))
            let line = R.line(.change, .waiting, text: StyledText("Waiting for your approval"))
            let approval = Approval(
                id: "run2.1", tile: Tile(glyph: .tool(.change), state: .waiting), title: "Edit \(runRow)",
                body: .change(
                    removed: ["        summary.font = .systemFont(ofSize: 13)"],
                    added: ["        summary.font = .systemFont(ofSize: 12)"]),
                reason: "Edits need approval in Ask Permissions mode.", request: "Claude wants to make this edit")
            return opening + [.run(id: "run2", line: line, items: [read, edit], waiting: approval)]
        case .noTabs, .newTab, .atRest, .failed, .split:
            return []
        }
    }

    /// `SEED.notes()`: a question about Ghostty's tab bar.
    private static var notes: [PlaygroundEntry] {
        typealias R = RowsSpecimen
        let items = [
            R.line(
                .search, text: StyledText("addTabButton", style: .code), detail: "in macos", meta: StyledText("3 files")
            ),
            R.line(
                .read, text: StyledText("TranscriptViewTests.swift", style: .noun(opens: nil)),
                detail: "macos/TranscriptKit/Tests/TranscriptKitTests", meta: StyledText("lines 1–120")),
        ]
        let line = R.line(
            .search,
            text: StyledText("Searched for ") + StyledText("addTabButton", style: .code)
                + StyledText(", read ") + R.file("TranscriptViewTests.swift"))
        return [
            .prompt("How does Ghostty draw the + at the end of its tab bar?"),
            .run(id: "run1", line: line, items: items, waiting: nil),
            .reply("It's a titlebar accessory view after the tab group — a borderless round button with a tooltip."),
        ]
    }

    /// The composer of the session in front, as the sheet's scenario sets it.
    private static func composer(_ scene: Scene) -> ComposerPresentation {
        typealias F = ComposerFixtures
        switch scene {
        case .responding:
            return F.state(model: "Sonnet 5.5", effort: ("Extra High", 4), mode: .acceptEdits, action: .stop)
        case .waiting:
            return F.waiting
        case .failed:
            return F.state(
                model: "Sonnet 5.5", effort: ("Extra High", 4), mode: .acceptEdits,
                failure: ComposerPresentation.Failure(
                    title: "Claude quit unexpectedly", detail: "Exit code 1",
                    output: "API Error: 529 overloaded_error · retries exhausted"))
        case .noTabs, .newTab, .atRest, .split:
            return F.atRest
        }
    }

    // MARK: - Tabs

    static func rowGapTab(_ scene: Scene) -> NSTabViewItem {
        item(
            PlaygroundTab(
                .session(entries: settled + turn(scene), composer: composer(scene)), title: "Row gap and tool rows"),
            identifier: rowGap)
    }

    static func tabBarTab() -> NSTabViewItem {
        item(
            PlaygroundTab(
                .session(
                    entries: notes,
                    composer: ComposerFixtures.state(model: "Opus 5.5", effort: ("High", 3), mode: .ask)),
                title: "Tab bar accessory"),
            identifier: tabBar)
    }

    /// A New tab, or the New view of a window with no tabs, in `folder`.
    static func newSession(in folder: String = "ccterm") -> PlaygroundTab {
        var content = NewSessionSpecimen.State.rest.content
        if folder != content.folderTitle {
            content.folderTitle = folder
            content.folderPath = "~/dev/\(folder)"
        }
        return PlaygroundTab(.draft(content), title: "New Session")
    }

    static func newTab(in folder: String = "ccterm") -> NSTabViewItem {
        item(newSession(in: folder), identifier: UUID())
    }

    private static func item(_ controller: NSViewController, identifier: AnyHashable) -> NSTabViewItem {
        let item = NSTabViewItem(viewController: controller)
        item.identifier = identifier
        return item
    }
}

// MARK: - The window's content

/// The main window's content as `MainSplitViewController` builds it: the
/// sidebar as a split's sidebar item, 290 to 350 wide (22 % of the window
/// between), beside the editor area, its tabs with the + and a live session's
/// mark; with no tab, a New view.
private final class MainWindowContent: NSView, EditorAreaViewControllerDelegate {
    private let split = NSSplitViewController()
    private let sidebar = SidebarViewController()
    private let editorArea = EditorAreaViewController()
    private let scene: PlaygroundSpecimen.Scene
    /// One mark per session shown in a tab, as the app keeps them.
    private var marks: [URL: ActivityMarkView] = [:]

    init(_ scene: PlaygroundSpecimen.Scene) {
        self.scene = scene
        super.init(frame: .zero)
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = Host.sidebarWidth
        sidebarItem.maximumThickness = Host.sidebarMaximumWidth
        sidebarItem.preferredThicknessFraction = 0.22
        sidebarItem.canCollapse = false
        sidebarItem.canCollapseFromWindowResize = false
        sidebarItem.titlebarSeparatorStyle = .automatic

        split.addSplitViewItem(sidebarItem)
        let detailItem = NSSplitViewItem(viewController: editorArea)
        detailItem.minimumThickness = Host.editorsMinimumWidth
        detailItem.canCollapse = false
        detailItem.titlebarSeparatorStyle = .none
        split.addSplitViewItem(detailItem)
        split.splitView.dividerStyle = .thin

        let content = split.view
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        sidebar.show(SidebarSpecimen.library)
        var activities = SidebarSpecimen.activities
        activities[PlaygroundSpecimen.rowGap] = scene.activity
        sidebar.show(activities)

        editorArea.delegate = self
        editorArea.showsNewTabButton = true
        editorArea.emptyViewController = PlaygroundSpecimen.newSession()
        switch scene {
        case .noTabs:
            // A window just opened: nothing chosen, every project closed.
            break
        case .newTab:
            editorArea.open(PlaygroundSpecimen.rowGapTab(scene), pinned: true)
            editorArea.open(PlaygroundSpecimen.newTab(), pinned: true)
            // Opened from the sidebar, the session stays selected there.
            sidebar.select(transcriptAt: PlaygroundSpecimen.rowGap)
        case .responding, .waiting, .atRest, .failed:
            editorArea.open(PlaygroundSpecimen.rowGapTab(scene), pinned: true)
            sidebar.select(transcriptAt: PlaygroundSpecimen.rowGap)
        case .split:
            // The second editor opens once the window has its size (`layout()`).
            editorArea.open(PlaygroundSpecimen.rowGapTab(scene), pinned: true)
            // Both sessions were opened from the sidebar, the second last.
            sidebar.select(transcriptAt: PlaygroundSpecimen.rowGap)
            sidebar.select(transcriptAt: PlaygroundSpecimen.tabBar)
        }
        editorArea.reloadIndicators()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private var hasSplit = false

    /// Split: the second editor opens at half the area, which it has only
    /// once the window is laid out — as a reader splits a window on screen.
    override func layout() {
        super.layout()
        guard scene == .split, !hasSplit, window != nil, bounds.width > 0 else { return }
        hasSplit = true
        DispatchQueue.main.async { [self] in
            layoutSubtreeIfNeeded()
            editorArea.addGroup(with: PlaygroundSpecimen.tabBarTab())?
                .addTabViewItem(PlaygroundSpecimen.newTab(in: "ghostty"))
            editorArea.reloadIndicators()
        }
    }

    /// A live session's mark in its tab — nothing while idle or at rest.
    func editorArea(_ editorArea: EditorAreaViewController, indicatorViewFor tabViewItem: NSTabViewItem) -> NSView? {
        guard let url = tabViewItem.identifier as? URL, url == PlaygroundSpecimen.rowGap,
            let activity = scene.activity, activity != .idle
        else { return nil }
        let mark = marks[url] ?? ActivityMarkView()
        marks[url] = mark
        mark.activity = activity
        return mark
    }
}
