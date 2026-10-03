import AppKit
import Components

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
            controller.view.frame = NSRect(origin: NSPoint(x: x, y: 20), size: size)
            addSubview(controller.view)
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
/// model on *Default (recommended)*, High effort, Auto mode, four recent
/// folders with ccterm chosen, and the branches the playground's ccterm has.
/// Glyphs are stand-ins in the glyph's box until the design's own arrive.
enum MenuFixtures {
    private static func glyph(_ name: String, _ point: CGFloat = 13) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        return image.withSymbolConfiguration(.init(pointSize: point, weight: .regular)) ?? image
    }

    private static func item(
        _ title: String, _ subtitle: String? = nil, glyph: NSImage? = nil, checked: Bool = false,
        enabled: Bool = true, danger: Bool = false
    ) -> MenuContent.Row {
        .item(
            MenuContent.Item(
                id: title, title: title, subtitle: subtitle, glyph: glyph, isChecked: checked, isEnabled: enabled,
                isDanger: danger))
    }

    static var effort: MenuContent {
        let meter = glyph("chart.bar")
        return MenuContent(rows: [
            .header(.title("Effort · Opus 5.5")),
            item("Low", glyph: meter), item("Medium", glyph: meter),
            item("High", "Default", glyph: meter, checked: true),
            item("Extra High", glyph: meter), item("Max", "This session only", glyph: meter),
        ])
    }

    static var mode: MenuContent {
        let mode = glyph("hand.raised")
        return MenuContent(rows: [
            .header(.title("Permission Mode", hint: "⇧⇥")),
            item("Ask Permissions", "Asks before edits and commands", glyph: mode),
            item("Accept Edits", "Edits files without asking; asks before commands", glyph: mode),
            item("Plan", "Reads and plans; changes nothing", glyph: mode),
            item("Auto", "Approves safe actions, asks when unsure", glyph: mode, checked: true),
            item("Don’t Ask", "Runs only what’s already allowed", glyph: mode),
            .separator,
            item("Bypass Permissions", "Runs everything without asking", glyph: mode, danger: true),
        ])
    }

    static var folder: MenuContent {
        let folder = glyph("folder", 11)
        func recent(_ title: String, _ path: String, checked: Bool = false) -> MenuContent.Row {
            .item(
                MenuContent.Item(
                    id: path, title: title, glyph: folder, isChecked: checked, trailing: .key(path), toolTip: path))
        }
        return MenuContent(rows: [
            .header(.title("Recent")),
            recent("ccterm", "~/dev/ccterm", checked: true), recent("ghostty", "~/dev/ghostty"),
            recent("claude-notes", "~/notes/claude-notes"), recent("dotfiles", "~/dotfiles"),
            .separator,
            .item(MenuContent.Item(id: "choose", title: "Choose Folder…", trailing: .key("⌘O"))),
        ])
    }

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

    static var model: MenuContent {
        let mark = NSImage.claudeMark.copy() as? NSImage ?? NSImage()
        mark.size = NSSize(width: 14, height: 14)
        let provider = glyph("server.rack", 14)
        return MenuContent(
            rows: [
                .header(.account(mark: mark, name: "Claude Max", detail: "Subscription", note: nil)),
                item("Default (recommended)", "Opus 5.5", checked: true), item("Opus 5.5"), item("Fable 5.1"),
                item("Sonnet 5.5"), item("Haiku 4.5"),
                .item(MenuContent.Item(id: "more", title: "7 More Models", isMore: true)),
                .header(.account(mark: provider, name: "Work Relay", detail: "relay.example.com", note: nil)),
                item("Default", "claude-sonnet-4-6"), item("Opus", "claude-opus-4-6"),
                item("Sonnet", "claude-sonnet-4-6"), item("Haiku", "claude-haiku-4-5"),
                .header(.account(mark: provider, name: "DeepSeek", detail: "api.deepseek.com", note: nil)),
                item("Default", "deepseek-v3.2"),
            ],
            footer: [
                .item(
                    MenuContent.Item(
                        id: "fast", title: "Fast Mode", subtitle: "Faster output on Opus · billed as extra usage",
                        glyph: glyph("bolt", 14), trailing: .toggle(isOn: false)))
            ], isPanel: true)
    }
}
