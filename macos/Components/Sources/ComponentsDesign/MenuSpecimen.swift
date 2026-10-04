import AppKit
import Components
import DisplayModels

/// The one menu (design/transcript, section 8 *Menus are popovers*): the
/// composer's three pop-ups open in their popovers over the composer, the
/// arrow on the chip — Model 300 wide, its list as tall as with every model
/// shown, Effort 240, Permission Mode 300 — then all five live, in real
/// `NSPopover`s. The New view's folder and branch are drawn open in its own
/// section.
enum MenuSpecimen {
    static func section() -> DesignPageViewController.Section {
        typealias F = ComposerFixtures
        return DesignPageViewController.Section(
            title: "Menus",
            note:
                "Every pop-up is one menu in a system popover, without its animation, of one size while it is "
                + "open: a section head, items with a check, a glyph, a title, a subtitle under it and a key, glyph "
                + "or switch at the trailing edge, greyed items with their reason, hairlines between groups. Rows sit "
                + "10 in and are 10 round, concentric with the popover's 20. The model list is as tall as it is with "
                + "every model shown, 360 at most, so More Models opens inside it, each account's head sticking to "
                + "its top and Fast Mode under it always in view.",
            specimens: [
                ComposerMenuHost(MenuFixtures.composer, .model).specimen("Model — a section per account"),
                ComposerMenuHost(F.responding, .model).specimen(
                    "Model while Claude works — another account restarts the CLI"),
                ComposerMenuHost(F.idle, .effort).specimen("Effort"),
                ComposerMenuHost(F.fastRing, .mode).specimen("Permission Mode — Fast on: Auto greyed with its reason"),
                ComposerMenuHost(F.haikuBypass, .mode).specimen("Permission Mode — Haiku in Bypass"),
                LiveMenus().specimen("The menus, live — click one to open its popover"),
            ])
    }
}

/// The composer at the transcript's column with `control`'s menu open in its
/// popover over the chip, the chip shown open — as the floating composer
/// opens it, or under the chip in a page.
private final class ComposerMenuHost: NSView {
    private let controller = ComposerViewController()
    private let panel = MenuPanelViewController()
    private let size: NSSize

    init(_ state: ComposerPresentation, _ control: ComposerMenu.Control) {
        controller.configure(with: state)
        let composer = controller.view
        composer.frame = NSRect(x: 0, y: 0, width: ComposerSpecimen.columnWidth, height: 400)
        composer.layoutSubtreeIfNeeded()
        let composerHeight = ceil(composer.fittingSize.height)
        composer.frame.size.height = composerHeight
        composer.layoutSubtreeIfNeeded()
        let below = state.placement == .page
        let edge: PopoverSurface.Edge = below ? .top : .bottom
        // The popover where it opens against the chip, in the composer's
        // flipped-free terms first; then the composer moves down by what the
        // popover sticks out over its top.
        var surface: PopoverSurface?
        var popoverFrame = NSRect.zero
        if let still = controller.menuStill(of: control) {
            panel.configure(with: still.content)
            let popover = panel.preferredSize
            surface = PopoverSurface(holding: panel.view, size: popover, edge: edge)
            let chip = composer.convert(still.chip.bounds, from: still.chip)
            // The composer's view is not flipped: its y runs up.
            let flippedChip = NSRect(
                x: chip.minX, y: composerHeight - chip.maxY, width: chip.width, height: chip.height)
            popoverFrame = PopoverSurface.frame(for: popover, edge: edge, against: flippedChip, flipped: true)
        }
        let overTop = max(0, -popoverFrame.minY)
        size = NSSize(
            width: ComposerSpecimen.columnWidth, height: max(composerHeight + overTop, popoverFrame.maxY + overTop))
        super.init(frame: NSRect(origin: .zero, size: size))
        composer.frame.origin = NSPoint(x: 0, y: overTop)
        addSubview(composer)
        if let surface {
            surface.frame = popoverFrame.offsetBy(dx: 0, dy: overTop)
            addSubview(surface)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }

    func specimen(_ title: String) -> DesignPageViewController.Specimen {
        .init(title: title, view: CentredHost(self, size: size), width: size.width, height: size.height)
    }
}

/// What the app's menus are built from, as the playground opens them: the
/// composer's own (`ComposerMenu`) on *Default (recommended)*, High effort and
/// Auto mode, the New view's folder menu over four recent folders with ccterm
/// chosen, and the branches the playground's ccterm has.
enum MenuFixtures {
    static let composer = ComposerFixtures.state(
        current: "model:\(ComposerFixtures.subscription.uuidString):default")

    static var effort: MenuContent { ComposerMenu.content(of: composer.effortMenu, width: ComposerMenu.effortWidth) }

    static var mode: MenuContent { ComposerMenu.content(of: composer.modeMenu, width: ComposerMenu.modeWidth) }

    static var folder: MenuContent { NewSessionViewController.folderMenu(of: NewSessionSpecimen.State.rest.content) }

    /// The branch picker, its list narrowed to the names holding `query`, as
    /// the New view draws it.
    static func branch(query: String = "") -> MenuContent {
        NewSessionViewController.branchMenu(of: branchMenu(query: query))
    }

    /// What the app lists for the branch picker: its branches holding `query`,
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
            ("main", "Checked out here", true), ("live-session-design", "Checked out in another worktree", false),
            ("fix-gutter-overflow", nil, true), ("exactlist-bench", nil, true), ("settings-accounts", nil, true),
        ])
        let remote = rows([("origin/release/1.4", nil, true), ("origin/sidebar-icons", nil, true)])
        var all: [NewSessionBranchMenu.Row] = []
        if !local.isEmpty { all += [.header("Local")] + local }
        if !remote.isEmpty { all += [.header("Remote")] + remote }
        if query.hasPrefix("#"), let number = Int(needle) {
            all += [
                .header("Pull Request"),
                .item(
                    NewSessionBranchMenu.Item(
                        id: number, title: "#\(number)", subtitle: "Checked out in a new worktree")),
            ]
        }
        return NewSessionBranchMenu(rows: all, query: query, emptyText: all.isEmpty ? "No Matching Branches" : nil)
    }

    static var model: MenuContent { model(expanded: []) }

    static func model(expanded: Set<UUID>) -> MenuContent {
        ComposerMenu.modelContent(of: composer, expanded: expanded)
    }
}

/// A button per menu that opens it in a real `NSPopover`, for hands: the
/// system's popover, keys and focus around the design's rows; the branch's
/// filter narrows it, *More Models* opens inside the model list, and nothing
/// moves while it is open.
private final class LiveMenus: NSView {
    private let entries: [(String, () -> MenuContent)] = [
        ("Model", { MenuFixtures.model }), ("Effort", { MenuFixtures.effort }),
        ("Permission Mode", { MenuFixtures.mode }), ("Folder", { MenuFixtures.folder }),
        ("Branch", { MenuFixtures.branch() }),
    ]
    private let popover = MenuPanel()
    private let buttons: [PillButton]

    init() {
        buttons = entries.map { PillButton(title: $0.0) }
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
        popover.onFilter = { [weak self] text in self?.popover.update(MenuFixtures.branch(query: text)) }
        popover.onChoose = { [weak self] item in
            guard case .more(let section) = item.id as? ComposerMenu.Choice else { return }
            self?.popover.update(MenuFixtures.model(expanded: [section]))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func specimen(_ title: String) -> DesignPageViewController.Specimen {
        .init(title: title, view: self, height: 64)
    }

    @objc private func open(_ sender: PillButton) {
        guard let index = buttons.firstIndex(of: sender) else { return }
        popover.close()
        popover.show(entries[index].1(), from: sender, preferring: .below)
    }
}
