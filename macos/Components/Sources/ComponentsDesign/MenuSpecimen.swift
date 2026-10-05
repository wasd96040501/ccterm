import AppKit
import Components
import DisplayModels

/// The menus (design/transcript, section 8 *Menus are popovers*): each one's
/// content as its `MenuPopover` holds it, at the popover's size — the frame,
/// the arrow and the material are the system's, which an off-screen page can't
/// open — then all five live, in real popovers from real buttons.
enum MenuSpecimen {
    static func section() -> DesignPageViewController.Section {
        typealias F = ComposerFixtures
        return DesignPageViewController.Section(
            title: "Menus",
            note:
                "Every pop-up is a system popover with its own fade, of one size while it is open, opened by "
                + "a button that shows its bezel under the pointer and stays on while the popover is up. Inside, "
                + "an inset table: heads, items with a check, a glyph, a title, a subtitle under it and a key, glyph "
                + "or switch at the trailing edge, greyed items with their reason, hairlines between groups. Each is "
                + "measured before it opens: as wide as its widest row and as tall as its rows, to 1.618 times its "
                + "least width — past that a path gives way in its middle and the list scrolls, Fast Mode staying "
                + "under the model list. The branch list sits under a search field, 264 tall whatever it holds. "
                + "Shown here is what each popover holds; the live row opens them.",
            specimens: [
                still(
                    "Model — every model, a section per account",
                    ComposerMenu.content(of: .model, in: MenuFixtures.composer)),
                still(
                    "Model while Claude works — another account restarts the CLI",
                    ComposerMenu.content(of: .model, in: F.responding)),
                still("Effort", ComposerMenu.content(of: .effort, in: F.idle)),
                still(
                    "Permission Mode — Fast on: Auto greyed with its reason",
                    ComposerMenu.content(of: .mode, in: F.fastRing)),
                still("Permission Mode — Haiku in Bypass", ComposerMenu.content(of: .mode, in: F.haikuBypass)),
                still("Folder", MenuFixtures.folder),
                still("Branch — Local then Remote, the default branch first", MenuFixtures.branch()),
                still("Branch — a number offers its pull request", MenuFixtures.branch(query: "#327")),
                still("Branch — nothing matches", MenuFixtures.branch(query: "zzz")),
                LiveMenus().specimen("The menus, live — press one to open its popover"),
            ])
    }

    /// What a popover holds for `content`, at the size it opens at.
    private static func still(_ title: String, _ content: MenuContent) -> DesignPageViewController.Specimen {
        let popover = MenuPopover()
        popover.configure(with: content)
        let size = popover.contentSize
        let view = popover.contentViewController?.view ?? NSView()
        return .init(
            title: title, view: CentredHost(view, size: size, owner: popover), width: size.width, height: size.height)
    }
}

/// What the app's menus are built from, as the playground opens them: the
/// composer's own (`ComposerMenu`) on *Default (recommended)*, High effort and
/// Auto mode, the New view's folder menu over four recent folders with ccterm
/// chosen, and the branches the playground's ccterm has, in the app's order.
enum MenuFixtures {
    static let composer = ComposerFixtures.state(
        current: "model:\(ComposerFixtures.subscription.uuidString):default")

    static var folder: MenuContent { NewSessionViewController.folderMenu(of: NewSessionSpecimen.State.rest.content) }

    /// The branch menu for what is typed in its search field, as the New view draws it.
    static func branch(query: String = "") -> MenuContent {
        NewSessionViewController.branchMenu(of: branchMenu(query: query))
    }

    /// What the app lists for the branch menu: its branches holding `query`,
    /// a leading `#` ignored, and for `#N` that pull request.
    static func branchMenu(query: String = "") -> NewSessionBranchMenu {
        let needle = query.hasPrefix("#") ? String(query.dropFirst()) : query
        func rows(_ names: [(String, String?, Bool)], chosen: String = "main") -> [NewSessionBranchMenu.Row] {
            names.filter { needle.isEmpty || $0.0.localizedCaseInsensitiveContains(needle) }.map {
                .item(
                    NewSessionBranchMenu.Item(
                        id: $0.0, title: $0.0, subtitle: $0.1, isChecked: $0.0 == chosen, isEnabled: $0.2,
                        toolTip: $0.0))
            }
        }
        let local = rows([
            ("main", "Current branch", true), ("live-session-design", "Checked out in another worktree", false),
            ("exactlist-bench", nil, true), ("fix-gutter-overflow", nil, true), ("settings-accounts", nil, true),
        ])
        let remote = rows([("origin/sidebar-icons", nil, true), ("origin/release/1.4", nil, true)])
        var all: [NewSessionBranchMenu.Row] = []
        if !local.isEmpty { all += [.header("Local")] + local }
        if !remote.isEmpty { all += [.header("Remote")] + remote }
        if query.hasPrefix("#"), let number = Int(needle) {
            all += [
                .header("Pull Request"),
                .item(
                    NewSessionBranchMenu.Item(
                        id: number, title: "#\(number)", subtitle: "Checks out in a new worktree")),
            ]
        }
        return NewSessionBranchMenu(rows: all, query: query, emptyText: all.isEmpty ? "No Matching Branches" : nil)
    }
}

/// A button per menu that opens it in its real popover, for hands: the
/// system's popover, keys and focus; the branch's search narrows it and
/// nothing moves while it is open.
private final class LiveMenus: NSView {
    private let entries: [(String, () -> MenuContent)] = [
        ("Model", { ComposerMenu.content(of: .model, in: MenuFixtures.composer) }),
        ("Effort", { ComposerMenu.content(of: .effort, in: MenuFixtures.composer) }),
        ("Permission Mode", { ComposerMenu.content(of: .mode, in: MenuFixtures.composer) }),
        ("Folder", { MenuFixtures.folder }), ("Branch", { MenuFixtures.branch() }),
    ]
    private let popover = MenuPopover()
    private let buttons: [NSButton]

    init() {
        buttons = entries.map { title, _ in
            let button = MenuButton()
            button.show(title, font: .systemFont(ofSize: 12), ink: .secondaryLabelColor)
            return button
        }
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
        popover.onSearch = { [weak self] words in self?.popover.configure(with: MenuFixtures.branch(query: words)) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func specimen(_ title: String) -> DesignPageViewController.Specimen {
        .init(title: title, view: self, height: 64)
    }

    @objc private func open(_ sender: NSButton) {
        guard let index = buttons.firstIndex(of: sender) else { return }
        if popover.isShown, popover.anchor === sender {
            popover.close()
            return
        }
        popover.configure(with: entries[index].1())
        popover.show(from: sender, above: false)
    }
}
