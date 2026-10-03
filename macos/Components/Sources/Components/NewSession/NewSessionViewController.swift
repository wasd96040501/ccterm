import AppKit
import DisplayModels

/// The New view (design 08): centred a third of the way down — the app icon
/// at 64 pt over its still glow, the folder as a 22-pt pop-up title with its
/// path under it, the branch pop-up and the Worktree toggle on one row that
/// never moves, the line that says what Send will do, then a slot for the
/// composer (640 pt).
///
/// The composer is not this view's: its container pins the composer's view to
/// `composerGuide`, and moves it out when the tab hands over. This view only
/// keeps the slot, which takes the height of what fills it.
///
/// Send's one motion is `rise(completion:)`: 600 ms, the icon's cursor lit
/// row by row from the bottom while the glow swells (design 08 *Send is the one
/// moment it moves*); Reduce Motion skips it. In Dark it draws the icon's
/// Dark rendition.
@MainActor
public final class NewSessionViewController: NSViewController {
    public weak var delegate: NewSessionViewControllerDelegate?

    /// Where the composer goes: 640 pt wide at most and 24 in from each side,
    /// centred, under the explanation line. The container sets its height to the composer's.
    public let composerGuide = NSLayoutGuide()

    private var content: NewSessionContent?
    private let prefersReducedMotion: () -> Bool
    private var riseCompletions: [@MainActor () -> Void] = []
    private var isRising = false
    /// Which rise is playing; a rise that was settled finds its timer stale.
    private var riseGeneration = 0
    /// The folder's or the branch's menu, whichever is open.
    private let popUpMenu = MenuPanel()
    private var openChip: NewSessionChip?
    /// The press on a chip that took the keyboard from its open menu closes
    /// it; the chip's action must not reopen it.
    private var lastClosed: (chip: NewSessionChip, at: TimeInterval)?
    /// What is typed in the branch menu's filter.
    private var branchQuery = ""

    /// The page's side margin (the design's `.lv-new` padding).
    private static let margin: CGFloat = 24

    private let iconView = NewSessionIconView()

    private lazy var folderChip: NewSessionChip = {
        let chip = NewSessionChip(title: String(localized: "Choose Folder…", bundle: .module), look: .folder)
        chip.sendsActionOnPress = true
        chip.target = self
        chip.action = #selector(showFolderMenu(_:))
        chip.setAccessibilityIdentifier("newSession.folder")
        chip.setAccessibilityRole(.popUpButton)
        return chip
    }()

    private lazy var pathLabel: NSTextField = {
        let label = Self.label(size: 11, color: .tertiaryLabelColor)
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }()

    private lazy var branchChip: NewSessionChip = {
        let chip = NewSessionChip(title: "", look: .row)
        // The design's branch glyph, 10 × 11 on the pop-up.
        let glyph = NSImage.sidebarWorktree.copy() as? NSImage ?? NSImage.sidebarWorktree
        glyph.size = NSSize(width: 10, height: 11)
        chip.glyph = glyph
        chip.toolTip = String(localized: "Branch", bundle: .module)
        chip.sendsActionOnPress = true
        chip.target = self
        chip.action = #selector(showBranchPicker(_:))
        chip.setAccessibilityIdentifier("newSession.branch")
        chip.setAccessibilityRole(.popUpButton)
        return chip
    }()

    private lazy var worktreeChip: NewSessionChip = {
        let chip = NewSessionChip(
            title: String(localized: "Worktree", bundle: .module), look: .row, showsChevron: false)
        // The design's worktree mark, at a control's 14 pt.
        let glyph = NSImage.newViewWorktree.copy() as? NSImage ?? NSImage.newViewWorktree
        glyph.size = NSSize(width: 14, height: 14)
        chip.glyph = glyph
        chip.toolTip = String(
            localized: "Work in a new git worktree (--worktree), leaving this folder as it is", bundle: .module)
        chip.target = self
        chip.action = #selector(toggleWorktree(_:))
        chip.setAccessibilityIdentifier("newSession.worktree")
        chip.setAccessibilityRole(.checkBox)
        return chip
    }()

    private lazy var notRepositoryLabel = Self.label(size: 12, color: .tertiaryLabelColor)
    private lazy var explanationLabel = Self.label(size: 11, color: .tertiaryLabelColor)

    private lazy var whereRow: NSView = {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }()

    /// `prefersReducedMotion` is the system's Reduce Motion setting; the rise
    /// is skipped under it.
    public init(
        prefersReducedMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    ) {
        self.prefersReducedMotion = prefersReducedMotion
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    public override func loadView() {
        view = NewSessionRootView { [weak self] in self?.chooseFolder(nil) }
        configureHierarchy()
        configureConstraints()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        popUpMenu.onChoose = { [weak self] item in self?.menuChose(item) }
        popUpMenu.onFilter = { [weak self] text in self?.menuFilterChanged(text) }
        popUpMenu.onClose = { [weak self] in self?.menuDidClose() }
        if let content { configure(with: content) }
    }

    public override func viewDidDisappear() {
        super.viewDidDisappear()
        popUpMenu.close()
    }

    // MARK: - Tree

    private func configureHierarchy() {
        for subview in [iconView, folderChip, pathLabel, whereRow, explanationLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        for subview in [branchChip, worktreeChip, notRepositoryLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            whereRow.addSubview(subview)
        }
        view.addLayoutGuide(composerGuide)
    }

    private func configureConstraints() {
        // A third of the way down, not the middle: the free space above the
        // content is 0.62 of the space below it (the optical centre).
        let above = NSLayoutGuide()
        let below = NSLayoutGuide()
        // Each line of words is the design's line box (its size × 1.45, the
        // note's 15), the words centred in it.
        let pathLine = NSLayoutGuide()
        let noteLine = NSLayoutGuide()
        for guide in [above, below, pathLine, noteLine] { view.addLayoutGuide(guide) }

        // Until a composer is in the slot, a composer's worth — weaker than any
        // view's hugging, so the composer in it keeps its own height.
        let slotHeight = composerGuide.heightAnchor.constraint(equalToConstant: 100)
        slotHeight.priority = .fittingSizeCompression
        let slotWidth = composerGuide.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -2 * Self.margin)
        slotWidth.priority = .wishUnderWindowSize

        NSLayoutConstraint.activate([
            above.topAnchor.constraint(equalTo: view.topAnchor),
            above.heightAnchor.constraint(equalTo: below.heightAnchor, multiplier: 0.62),
            iconView.topAnchor.constraint(equalTo: above.bottomAnchor),
            composerGuide.bottomAnchor.constraint(equalTo: below.topAnchor),
            below.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            iconView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            folderChip.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 16),
            folderChip.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            folderChip.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -2 * Self.margin),
            pathLine.topAnchor.constraint(equalTo: folderChip.bottomAnchor, constant: 2),
            pathLine.heightAnchor.constraint(equalToConstant: 16),
            pathLabel.centerYAnchor.constraint(equalTo: pathLine.centerYAnchor),
            pathLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pathLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -2 * Self.margin),
            whereRow.topAnchor.constraint(equalTo: pathLine.bottomAnchor, constant: 8),
            whereRow.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            whereRow.heightAnchor.constraint(equalToConstant: 24),
            whereRow.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -2 * Self.margin),
            noteLine.topAnchor.constraint(equalTo: whereRow.bottomAnchor, constant: 2),
            noteLine.heightAnchor.constraint(equalToConstant: 15),
            explanationLabel.centerYAnchor.constraint(equalTo: noteLine.centerYAnchor),
            explanationLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            explanationLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -2 * Self.margin),

            branchChip.leadingAnchor.constraint(equalTo: whereRow.leadingAnchor),
            branchChip.centerYAnchor.constraint(equalTo: whereRow.centerYAnchor),
            branchChip.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
            worktreeChip.leadingAnchor.constraint(equalTo: branchChip.trailingAnchor, constant: 8),
            worktreeChip.trailingAnchor.constraint(equalTo: whereRow.trailingAnchor),
            worktreeChip.centerYAnchor.constraint(equalTo: whereRow.centerYAnchor),
            notRepositoryLabel.centerXAnchor.constraint(equalTo: whereRow.centerXAnchor),
            notRepositoryLabel.centerYAnchor.constraint(equalTo: whereRow.centerYAnchor),
            notRepositoryLabel.leadingAnchor.constraint(equalTo: whereRow.leadingAnchor),
            notRepositoryLabel.trailingAnchor.constraint(equalTo: whereRow.trailingAnchor),

            composerGuide.topAnchor.constraint(equalTo: noteLine.bottomAnchor, constant: 20),
            composerGuide.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            composerGuide.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
            composerGuide.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -2 * Self.margin),
            slotWidth,
            slotHeight,
        ])
    }

    // MARK: - Showing the model

    /// Shows `content`. Idempotent.
    public func configure(with content: NewSessionContent) {
        self.content = content
        guard isViewLoaded else { return }

        folderChip.title = content.folderTitle
        if popUpMenu.isShown, let menu = menuContent(for: openChip) { popUpMenu.update(menu) }
        pathLabel.stringValue = content.folderPath ?? ""
        explanationLabel.stringValue = content.explanation ?? ""

        switch content.branchRow {
        case .repository(let branchTitle, let usesWorktree):
            branchChip.isHidden = false
            worktreeChip.isHidden = false
            notRepositoryLabel.isHidden = true
            branchChip.title = branchTitle
            worktreeChip.isOn = usesWorktree
            worktreeChip.setAccessibilityValue(usesWorktree ? 1 : 0)
        case .notARepository(let words):
            branchChip.isHidden = true
            worktreeChip.isHidden = true
            notRepositoryLabel.isHidden = false
            notRepositoryLabel.stringValue = words
        case .loading:
            branchChip.isHidden = true
            worktreeChip.isHidden = true
            notRepositoryLabel.isHidden = true
        }
    }

    /// Plays Send's rise and calls `completion` when it ends (at once under
    /// Reduce Motion). The field's words stay, dimmed, until then — the
    /// container's to dim.
    public func rise(completion: @escaping @MainActor () -> Void) {
        if prefersReducedMotion() {
            completion()
            return
        }
        riseCompletions.append(completion)
        guard !isRising else { return }
        isRising = true
        view.layoutSubtreeIfNeeded()
        iconView.rise()
        let generation = riseGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + NewSessionIconView.riseDuration) { [weak self] in
            guard let self, riseGeneration == generation else { return }
            isRising = false
            let completions = riseCompletions
            riseCompletions = []
            for completion in completions { completion() }
        }
    }

    /// Ends a rise that is playing, back to rest at once; its completions
    /// are dropped, never called (Stop during the rise). Does nothing when
    /// none is playing.
    public func settleRise() {
        guard isRising else { return }
        riseGeneration += 1
        isRising = false
        riseCompletions = []
        iconView.settle()
    }

    // MARK: - The folder

    @objc private func showFolderMenu(_ sender: NSControl) {
        open(folderChip)
    }

    /// *Choose Folder…* (⌘O): an open panel for the folder Claude will work in.
    @objc private func chooseFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose the folder Claude will work in.", bundle: .module)
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard let self, response == .OK, let url = panel?.url else { return }
            delegate?.newSessionViewController(self, didChooseFolder: url)
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    // MARK: - The branch

    @objc private func showBranchPicker(_ sender: NSControl) {
        branchQuery = ""
        open(branchChip)
    }

    // MARK: - The menus

    /// What `chip`'s menu shows now.
    private func menuContent(for chip: NewSessionChip?) -> MenuContent? {
        guard let content else { return nil }
        if chip === folderChip { return Self.folderMenu(of: content) }
        if chip === branchChip, case .repository = content.branchRow {
            return delegate?.newSessionViewController(self, branchMenuMatching: branchQuery)
        }
        return nil
    }

    /// What a chosen item of the folder menu stands for.
    enum FolderChoice: Hashable {
        case folder(URL)
        case chooseFolder
    }

    /// The folder's menu (design 08 *The New view*): *Recent*, each folder
    /// with its glyph and its path at the trailing edge, then *Choose Folder…
    /// ⌘O* past a hairline.
    package static func folderMenu(of content: NewSessionContent) -> MenuContent {
        var rows: [MenuContent.Row] = []
        if !content.recentFolders.isEmpty {
            rows.append(.header(.title(String(localized: "Recent", bundle: .module))))
            // The sheet's folder (10.4 × 9.2 of the row's 16), as SF Symbols draws it.
            let glyph = NSImage.symbol("folder", pointSize: 11)
            for folder in content.recentFolders {
                rows.append(
                    .item(
                        MenuContent.Item(
                            id: FolderChoice.folder(folder.url), title: folder.title, glyph: glyph,
                            isChecked: folder.isChosen, trailing: .key(folder.path), toolTip: folder.path)))
            }
            rows.append(.separator)
        }
        rows.append(
            .item(
                MenuContent.Item(
                    id: FolderChoice.chooseFolder, title: String(localized: "Choose Folder…", bundle: .module),
                    trailing: .key("⌘O"))))
        return MenuContent(rows: rows)
    }

    /// Opens `chip`'s menu under it, or closes it when it is the one open.
    private func open(_ chip: NewSessionChip) {
        let wasOpen = openChip
        popUpMenu.close()
        guard wasOpen !== chip else { return }
        if let lastClosed, lastClosed.chip === chip, ProcessInfo.processInfo.systemUptime - lastClosed.at < 0.5 {
            return
        }
        guard let content = menuContent(for: chip) else { return }
        openChip = chip
        chip.isOpen = true
        popUpMenu.show(content, from: chip, preferring: .below)
    }

    private func menuChose(_ item: MenuContent.Item) {
        if let choice = item.id.base as? FolderChoice {
            switch choice {
            case .folder(let url): delegate?.newSessionViewController(self, didChooseFolder: url)
            case .chooseFolder: chooseFolder(nil)
            }
        } else {
            delegate?.newSessionViewController(self, didChooseBranchItem: item.id)
        }
    }

    private func menuFilterChanged(_ text: String) {
        branchQuery = text
        if let content = menuContent(for: openChip) { popUpMenu.update(content) }
    }

    private func menuDidClose() {
        if let openChip {
            openChip.isOpen = false
            lastClosed = (openChip, ProcessInfo.processInfo.systemUptime)
        }
        openChip = nil
    }

    @objc private func toggleWorktree(_ sender: NSControl) {
        delegate?.newSessionViewControllerDidToggleWorktree(self)
    }

    // MARK: - Pieces

    private static func label(size: CGFloat, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: size)
        label.textColor = color
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}

/// The view, answering ⌘O (*Choose Folder…*) while it is on screen.
@MainActor
private final class NewSessionRootView: NSView {
    private let chooseFolder: () -> Void

    init(chooseFolder: @escaping () -> Void) {
        self.chooseFolder = chooseFolder
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "o" {
            chooseFolder()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
