import AppKit
import Components
import DisplayModels

/// The one menu (design/transcript, section 8 *Menus*, `.lv-menu`): the five
/// pop-ups of the composer and the New view, each at the width the design
/// measures it — Effort 240, Permission mode 330, Folder 295, Branch 300 and
/// the model panel 300, whose list scrolls past 360 with Fast Mode under it.
/// A menu is as wide as its widest row, a panel is 300; nothing is stretched.
enum MenuSpecimen {
    static func section() -> DesignPageViewController.Section {
        DesignPageViewController.Section(
            title: "Menus",
            note:
                "Every pop-up is one menu: a section head, items with a check, a glyph, a title, a subtitle under "
                + "it and a key, glyph or switch at the trailing edge, greyed items with their reason, hairlines "
                + "between groups. A panel is 300 wide and its list scrolls past 360 under each account's sticky "
                + "head, with what follows (Fast Mode) always in view; the branch picker adds a filter field.",
            specimens: [
                MenuRow([MenuFixtures.effort, MenuFixtures.mode, MenuFixtures.folder]).specimen(
                    "Menus — Effort, Permission mode, Folder"),
                MenuRow([MenuFixtures.branch(), MenuFixtures.model]).specimen(
                    "Panels — Branch with its filter, Model with Fast Mode under the scroll"),
                LiveMenus([
                    ("Effort", MenuFixtures.effort), ("Permission Mode", MenuFixtures.mode),
                    ("Folder", MenuFixtures.folder),
                ]).specimen("The menus, live — click one to open it"),
            ])
    }
}

/// Menus side by side, each at its own size, top-aligned in a plain card: a
/// panel as the panel draws it, a menu as its `NSMenu` does (`StaticMenuView`).
final class MenuRow: NSView {
    /// What draws each: a panel's controller or a menu's `SystemMenu`.
    private let owners: [AnyObject]
    /// The row's size: its menus at their own sizes, 24 apart and from the edges.
    let size: NSSize

    init(_ contents: [MenuContent]) {
        var owners: [AnyObject] = []
        var views: [(NSView, NSSize)] = []
        for content in contents {
            if content.isPanel {
                let controller = MenuPanelViewController()
                controller.configure(with: content)
                owners.append(controller)
                views.append((controller.view, controller.preferredSize))
            } else {
                let menu = SystemMenu()
                menu.configure(with: content)
                owners.append(menu)
                let view = StaticMenuView(menu.menu)
                views.append((view, view.frame.size))
            }
        }
        self.owners = owners
        size = NSSize(
            width: views.reduce(24) { $0 + $1.1.width + 24 }, height: (views.map(\.1.height).max() ?? 0) + 40)
        super.init(frame: .zero)
        // Placed by frame, as a window places its content view.
        var x: CGFloat = 24
        for (view, size) in views {
            let surface = ElevatedView.popover(holding: view)
            surface.frame = NSRect(origin: NSPoint(x: x, y: 20), size: size)
            addSubview(surface)
            x += size.width + 24
        }
        heightAnchor.constraint(equalToConstant: size.height).isActive = true
    }

    /// This row as a specimen at its own size.
    func specimen(_ title: String) -> DesignPageViewController.Specimen {
        .init(title: title, view: self, width: size.width, height: size.height)
    }

    override var isFlipped: Bool { true }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

/// What the app's menus are built from, as the playground opens them: the
/// composer's own (`ComposerMenu`) on *Default (recommended)*, High effort and
/// Auto mode, the New view's folder menu over four recent folders with ccterm
/// chosen, and the branches the playground's ccterm has.
enum MenuFixtures {
    private static let composer = ComposerFixtures.state(
        current: "model:\(ComposerFixtures.subscription.uuidString):default")

    static var effort: MenuContent { ComposerMenu.content(of: composer.effortMenu) }

    static var mode: MenuContent { ComposerMenu.content(of: composer.modeMenu) }

    static var folder: MenuContent { NewSessionViewController.folderMenu(of: NewSessionSpecimen.State.rest.content) }

    /// The branch picker, its list narrowed to the names holding `query`, as
    /// the New view draws it.
    static func branch(query: String = "") -> MenuContent {
        NewSessionViewController.branchMenu(of: branchMenu(query: query))
    }

    /// What the app lists for the branch picker: its branches holding `query`.
    static func branchMenu(query: String = "") -> NewSessionBranchMenu {
        func rows(_ names: [(String, String?, Bool)], chosen: String = "main") -> [NewSessionBranchMenu.Row] {
            names.filter { query.isEmpty || $0.0.localizedCaseInsensitiveContains(query) }.map {
                .item(
                    NewSessionBranchMenu.Item(
                        id: $0.0, title: $0.0, subtitle: $0.1, isChecked: $0.0 == chosen, isEnabled: $0.2,
                        toolTip: $0.0))
            }
        }
        let local = rows([
            ("main", "Checked out here", true), ("live-session-design", "Checked out in another worktree", false),
            ("fix-gutter-overflow", nil, true), ("exactlist-bench", nil, true), ("settings-accounts", nil, true),
        ])
        let remote = rows([("origin/release/1.4", nil, true), ("origin/sidebar-icons", nil, true)])
        var all: [NewSessionBranchMenu.Row] = []
        if !local.isEmpty { all += [.header("Local")] + local }
        if !remote.isEmpty { all += [.header("Remote")] + remote }
        return NewSessionBranchMenu(rows: all, query: query)
    }

    static var model: MenuContent { ComposerMenu.modelContent(of: composer, expanded: []) }
}

/// A button per menu that pops its real `NSMenu` under it, for hands: the
/// system's tracking, keys and chrome around the design's rows.
private final class LiveMenus: NSView {
    private let menus: [SystemMenu]
    private let buttons: [PillButton]

    init(_ entries: [(String, MenuContent)]) {
        menus = entries.map { _, content in
            let menu = SystemMenu()
            menu.configure(with: content)
            return menu
        }
        buttons = entries.map { title, _ in PillButton(title: title) }
        super.init(frame: .zero)
        let stack = NSStackView(views: buttons)
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 64),
        ])
        for button in buttons {
            button.target = self
            button.action = #selector(open(_:))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func specimen(_ title: String) -> DesignPageViewController.Specimen {
        .init(title: title, view: self, height: 64)
    }

    @objc private func open(_ sender: PillButton) {
        guard let index = buttons.firstIndex(of: sender) else { return }
        menus[index].popUp(from: sender, on: .below, gap: 4, leadingOffset: -4)
    }
}
