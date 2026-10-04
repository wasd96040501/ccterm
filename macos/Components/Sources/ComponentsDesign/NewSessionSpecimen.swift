import AppKit
import Components
import DisplayModels

/// The New view (design/transcript, section 8 *The New view*, and the
/// Playground's window with no tabs): the app icon over its glow, the folder
/// as the page's title, the branch and Worktree on a row that never moves, the
/// line that says what Send will do, and the composer's slot — a card stands in
/// for the composer, which is the app's. Each state the sheet shows, then the
/// two menus open under their chips.
enum NewSessionSpecimen {
    /// The pane a New tab gets in the sheet's main window (900 × 642, under its
    /// title bar and tab bar): the host the app puts the view in.
    static let pane = NSSize(width: 900, height: 642)

    static func section() -> DesignPageViewController.Section {
        DesignPageViewController.Section(
            title: "New view",
            note:
                "A window with no tabs opens on it, and so does a New tab: the app icon over its still glow, the "
                + "folder as a 22-pt title with its path under it, the branch pop-up and the Worktree toggle on one "
                + "row that never moves, and under it the line that says what Send will do. The composer sits in "
                + "the slot under that, 640 wide at most, a third of the way down the pane. A folder that isn't a "
                + "git repository says so at the row's height, so the composer doesn't move. Click the folder or "
                + "the branch for its menu; Worktree toggles.",
            specimens: [
                .init(title: "A folder, in place", view: host(.rest), height: nil),
                .init(title: "Worktree on — the line says what Send will do", view: host(.worktree), height: nil),
                .init(title: "A folder that isn't a git repository", view: host(.notARepository), height: nil),
                .init(title: "No folder yet", view: host(.noFolder), height: nil),
                .init(title: "The folder menu", view: host(.rest, menu: .folder), height: nil),
                .init(title: "The branch menu", view: host(.rest, menu: .branch), height: nil),
            ])
    }

    private static func host(_ state: State, menu: Menu? = nil) -> NSView {
        NewSessionHost(state: state, menu: menu)
    }

    enum State {
        case rest, worktree, notARepository, noFolder

        var content: NewSessionContent {
            let home = NSHomeDirectory()
            let recents = [
                NewSessionContent.Folder(
                    url: URL(fileURLWithPath: home + "/dev/ccterm"), title: "ccterm", path: "~/dev/ccterm",
                    isChosen: self != .noFolder && self != .notARepository),
                .init(url: URL(fileURLWithPath: home + "/dev/ghostty"), title: "ghostty", path: "~/dev/ghostty"),
                .init(
                    url: URL(fileURLWithPath: home + "/notes/claude-notes"), title: "claude-notes",
                    path: "~/notes/claude-notes"),
                .init(url: URL(fileURLWithPath: home + "/dotfiles"), title: "dotfiles", path: "~/dotfiles"),
            ]
            switch self {
            case .rest:
                return NewSessionContent(
                    folderTitle: "ccterm", folderPath: "~/dev/ccterm", recentFolders: recents,
                    branchRow: .repository(branchTitle: "main", usesWorktree: false))
            case .worktree:
                return NewSessionContent(
                    folderTitle: "ccterm", folderPath: "~/dev/ccterm", recentFolders: recents,
                    branchRow: .repository(branchTitle: "main", usesWorktree: true),
                    explanation: "A new branch from main, in a new worktree")
            case .notARepository:
                return NewSessionContent(
                    folderTitle: "claude-notes", folderPath: "~/notes/claude-notes", recentFolders: recents,
                    branchRow: .notARepository("Not a git repository"))
            case .noFolder:
                return NewSessionContent(
                    folderTitle: "Choose Folder…", recentFolders: recents, branchRow: .loading)
            }
        }
    }

    enum Menu { case folder, branch }
}

/// The view in its pane at the pane's real size, centred, with a menu drawn
/// open under its chip when asked for. It answers the
/// view's delegate from the fixture, so the page stays live.
@MainActor
private final class NewSessionHost: NSView, NewSessionViewControllerDelegate {
    private let controller = NewSessionViewController()
    private let stage = NSView()
    private let openMenu: NewSessionSpecimen.Menu?
    private var content: NewSessionContent
    /// What draws the open menu: the folder's `SystemMenu`, the branch's panel.
    private var menuOwner: AnyObject?
    private var menuSize = NSSize.zero
    private var menuSurface: ElevatedView?

    init(state: NewSessionSpecimen.State, menu: NewSessionSpecimen.Menu?) {
        content = state.content
        openMenu = menu
        super.init(frame: .zero)
        controller.delegate = self
        controller.loadViewIfNeeded()
        controller.configure(with: content)

        stage.wantsLayer = true
        // The view is the pane's size always.
        controller.view.frame = NSRect(origin: .zero, size: NewSessionSpecimen.pane)
        stage.addSubview(controller.view)
        addSubview(stage)

        // The composer's stand-in: a card in the slot.
        let card = SlotCard()
        card.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(card)
        NSLayoutConstraint.activate([
            controller.composerGuide.heightAnchor.constraint(equalToConstant: 96),
            card.leadingAnchor.constraint(equalTo: controller.composerGuide.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: controller.composerGuide.trailingAnchor),
            card.topAnchor.constraint(equalTo: controller.composerGuide.topAnchor),
            card.bottomAnchor.constraint(equalTo: controller.composerGuide.bottomAnchor),
        ])

        if let menu {
            // The folder's is an `NSMenu`, shown by its own rows; the branch's
            // is a panel, for its filter.
            let view: NSView
            if menu == .folder {
                let folder = SystemMenu()
                folder.configure(with: NewSessionViewController.folderMenu(of: content))
                menuOwner = folder
                view = StaticMenuView(folder.menu)
                menuSize = view.frame.size
            } else {
                let panel = MenuPanelViewController()
                panel.configure(with: branchMenu())
                panel.loadViewIfNeeded()
                menuOwner = panel
                menuSize = panel.preferredSize
                view = panel.view
            }
            let surface = ElevatedView.popover(holding: view)
            menuSurface = surface
            stage.addSubview(surface)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NewSessionSpecimen.pane.width, height: NewSessionSpecimen.pane.height)
    }

    override func layout() {
        super.layout()
        let pane = NewSessionSpecimen.pane
        stage.frame = NSRect(
            origin: NSPoint(x: ((bounds.width - pane.width) / 2).rounded(), y: 0), size: pane)
        stage.layoutSubtreeIfNeeded()
        placeMenu()
    }

    /// The menu under the chip that opens it, as the pop-up shows it.
    private func placeMenu() {
        guard let menuSurface, let menu = openMenu else { return }
        let id = menu == .folder ? "newSession.folder" : "newSession.branch"
        guard let chip = Self.find(id, in: controller.view) else { return }
        let size = menuSize
        let chipFrame = stage.convert(chip.bounds, from: chip)
        // `stage` is not flipped: its y runs up, so under the chip is lower.
        menuSurface.frame = NSRect(
            x: chipFrame.minX, y: chipFrame.minY - 4 - size.height, width: size.width, height: size.height)
    }

    private static func find(_ identifier: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == identifier { return view }
        return view.subviews.lazy.compactMap { find(identifier, in: $0) }.first
    }

    // MARK: - The view's delegate

    func newSessionViewController(_ newSessionViewController: NewSessionViewController, didChooseFolder url: URL) {
        content.folderTitle = url.lastPathComponent
        content.folderPath = (url.path as NSString).abbreviatingWithTildeInPath
        controller.configure(with: content)
    }

    func newSessionViewControllerDidToggleWorktree(_ newSessionViewController: NewSessionViewController) {
        guard case .repository(let title, let on) = content.branchRow else { return }
        content.branchRow = .repository(branchTitle: title, usesWorktree: !on)
        content.explanation = on ? nil : "A new branch from \(title), in a new worktree"
        controller.configure(with: content)
    }

    func newSessionViewController(
        _ newSessionViewController: NewSessionViewController, branchMenuMatching query: String
    ) -> MenuContent? {
        branchMenu(query: query)
    }

    func newSessionViewController(
        _ newSessionViewController: NewSessionViewController, didChooseBranchItem id: AnyHashable
    ) {
        guard case .repository(_, let on) = content.branchRow, let name = id.base as? String else { return }
        content.branchRow = .repository(branchTitle: name, usesWorktree: on)
        controller.configure(with: content)
    }

    private func branchMenu(query: String = "") -> MenuContent { MenuFixtures.branch(query: query) }
}

/// What stands for the composer: the window's colour in a hairline, 18-pt
/// continuous corners.
private final class SlotCard: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}
