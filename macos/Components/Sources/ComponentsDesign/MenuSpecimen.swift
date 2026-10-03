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
            ])
    }
}

/// Menus side by side, each at its own size, top-aligned in a plain card.
final class MenuRow: NSView {
    private let controllers: [MenuPanelViewController]
    /// The row's size: its menus at their own sizes, 24 apart and from the edges.
    let size: NSSize

    init(_ contents: [MenuContent]) {
        controllers = contents.map {
            let controller = MenuPanelViewController()
            controller.configure(with: $0)
            return controller
        }
        var width: CGFloat = 24
        var height: CGFloat = 0
        for controller in controllers {
            width += controller.preferredSize.width + 24
            height = max(height, controller.preferredSize.height)
        }
        size = NSSize(width: width, height: height + 40)
        super.init(frame: .zero)
        // Placed by frame, as a window places its content view.
        var x: CGFloat = 24
        var tallest: CGFloat = 0
        for controller in controllers {
            let size = controller.preferredSize
            let surface = ElevatedView.popover(holding: controller.view)
            surface.frame = NSRect(origin: NSPoint(x: x, y: 20), size: size)
            addSubview(surface)
            x += size.width + 24
            tallest = max(tallest, size.height)
        }
        heightAnchor.constraint(equalToConstant: tallest + 40).isActive = true
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

    /// The branch picker, its list narrowed to the names holding `query`.
    static func branch(query: String = "") -> MenuContent {
        func rows(_ names: [(String, String?, Bool)], chosen: String = "main") -> [MenuContent.Row] {
            names.filter { query.isEmpty || $0.0.localizedCaseInsensitiveContains(query) }.map {
                .item(
                    MenuContent.Item(
                        id: $0.0, title: $0.0, subtitle: $0.1, isChecked: $0.0 == chosen, isEnabled: $0.2,
                        toolTip: $0.0))
            }
        }
        let local = rows([
            ("main", "Checked out here", true), ("live-session-design", "Checked out in another worktree", false),
            ("fix-gutter-overflow", nil, true), ("exactlist-bench", nil, true), ("settings-accounts", nil, true),
        ])
        let remote = rows([("origin/release/1.4", nil, true), ("origin/sidebar-icons", nil, true)])
        var all: [MenuContent.Row] = []
        if !local.isEmpty { all += [.header(.title("Local"))] + local }
        if !remote.isEmpty { all += [.header(.title("Remote"))] + remote }
        return MenuContent(rows: all, filter: MenuContent.Filter(placeholder: "Filter", text: query))
    }

    static var model: MenuContent { ComposerMenu.modelContent(of: composer, expanded: []) }
}
