import AppKit
import DisplayModels

/// The New view (design 08 *The New view*): one column — the app icon at
/// 64 pt over its still glow, the composer's slot, and under it where Claude
/// works (the folder's pop-up, the branch's, the *Use a new worktree*
/// checkbox) with the line that says what Send will do.
///
///     view                    the page: places the column, nothing else
///     └─ column               the unit: 640 wide at most, 24 from each side,
///        │                    centred — the one width the page decides
///        ├─ iconView          centred in the column, at its top
///        ├─ composerGuide     the column's width, 24 under the icon
///        ├─ controlsRow       8 under the slot, on the card's inner line
///        └─ explanationLabel  under the row, an overlay below the column
///
/// Everything in the column is placed against the column alone. Its width is
/// the one wish here (as wide as allowed, `.wish`); what fills it never
/// negotiates it. The card's top edge sits at the optical centre: what grows
/// — more lines, the note, an error — grows down, and nothing above it moves.
///
/// The composer is not this view's: its container pins the composer's view
/// to `composerGuide` — the column's slot — and moves it out when the tab
/// hands over. The slot takes the height of what fills it.
///
/// Send's one motion is `rise(completion:)`: 600 ms, the icon's cursor lit
/// row by row from the bottom while the glow swells (design 08 *Send is the one
/// moment it moves*); Reduce Motion skips it. In Dark it draws the icon's
/// Dark rendition.
@MainActor
public final class NewSessionViewController: NSViewController {
    public weak var delegate: NewSessionViewControllerDelegate?

    /// Where the composer goes: the column's width, 24 under the icon. The
    /// container pins the composer's view to it and sets its height to the
    /// composer's.
    public let composerGuide = NSLayoutGuide()

    /// The icon, the slot, the row and the note: the unit the page places.
    private let column = NSView()

    private var content: NewSessionContent?
    private let prefersReducedMotion: () -> Bool
    private var riseCompletions: [@MainActor () -> Void] = []
    private var isRising = false
    /// Which rise is playing; a rise that was settled finds its timer stale.
    private var riseGeneration = 0
    /// The folder's or the branch's menu, whichever is open.
    private let menuPopover = MenuPopover()
    /// What is typed in the branch menu's search field.
    private var branchQuery = ""

    /// The page's side margin (the design's `.lv-new` padding).
    private static let margin: CGFloat = 24
    /// The column at its widest.
    private static let columnWidth: CGFloat = 640
    /// The row's controls' bezels start this far in from the slot's edge,
    /// their words on the card's 16-pt inner line.
    private static let rowInset: CGFloat = 8
    /// The row's line: 8 under the slot, 28 tall.
    private static let rowGap: CGFloat = 8
    private static let rowHeight: CGFloat = 28
    /// The row's words, and the space the branch and the checkbox keep
    /// after the folder past the stack's 4.
    private static let rowFont = NSFont.systemFont(ofSize: 12)
    private static let groupGap: CGFloat = 12

    private let iconView = NewSessionIconView()

    /// The folder: its name in label ink, the one choice Send makes final;
    /// its path is the tooltip.
    private lazy var folderButton: MenuButton = {
        let button = MenuButton()
        button.lineBreakMode = .byTruncatingMiddle
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.target = self
        button.action = #selector(showFolderMenu(_:))
        button.setAccessibilityIdentifier("newSession.folder")
        return button
    }()

    private lazy var branchButton: MenuButton = {
        let button = MenuButton()
        button.lineBreakMode = .byTruncatingMiddle
        button.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        button.toolTip = String(localized: "Branch", bundle: .module)
        button.target = self
        button.action = #selector(showBranchMenu(_:))
        button.setAccessibilityIdentifier("newSession.branch")
        return button
    }()

    /// On while the session gets a worktree of its own: an option for Send,
    /// as a checkbox is in a save panel.
    private lazy var worktreeCheckbox: NSButton = {
        let button = NSButton(
            checkboxWithTitle: String(localized: "Use a new worktree", bundle: .module), target: self,
            action: #selector(toggleWorktree(_:)))
        button.attributedTitle = NSAttributedString(
            string: button.title, attributes: [.font: Self.rowFont, .foregroundColor: NSColor.secondaryLabelColor])
        button.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        button.toolTip = String(
            localized: "Work in a new git worktree (--worktree), leaving this folder as it is", bundle: .module)
        button.setAccessibilityIdentifier("newSession.worktree")
        return button
    }()

    private lazy var notRepositoryLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = Self.rowFont
        label.textColor = .tertiaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    /// What the choices add up to, in tertiary under the row, its words
    /// under the folder's glyph; one line, the middle giving way (a branch's
    /// name), and no room taken while there is nothing to say.
    private lazy var explanationLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    /// The note's words start where the folder's glyph does.
    private lazy var noteLeading = explanationLabel.leadingAnchor.constraint(equalTo: folderButton.leadingAnchor)

    /// The folder, then the branch and the checkbox or the line that says
    /// the folder isn't a repository: whichever shows; a hidden view takes
    /// no room.
    private lazy var controlsRow: NSStackView = {
        let row = NSStackView(views: [folderButton, branchButton, worktreeCheckbox, notRepositoryLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4
        row.setCustomSpacing(Self.groupGap, after: branchButton)
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
        view = NSView()
        configureHierarchy()
        configureConstraints()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        menuPopover.onChoose = { [weak self] item in self?.menuChose(item) }
        menuPopover.onSearch = { [weak self] words in self?.branchSearchChanged(words) }
        if let content { configure(with: content) }
    }

    public override func viewDidDisappear() {
        super.viewDidDisappear()
        menuPopover.close()
    }

    // MARK: - Tree

    private func configureHierarchy() {
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)
        for subview in [iconView, controlsRow, explanationLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            column.addSubview(subview)
        }
        column.addLayoutGuide(composerGuide)
    }

    private func configureConstraints() {
        configurePageConstraints()
        configureColumnConstraints()
    }

    /// The page places the column: centred, 640 wide unless the page less
    /// its margins is narrower — the one wish, so nothing in the column, the
    /// split it stands in or the window is moved for it — and the card's top
    /// a third of the way down (the space above it 0.62 of the space below).
    private func configurePageConstraints() {
        let above = NSLayoutGuide()
        let below = NSLayoutGuide()
        for guide in [above, below] { view.addLayoutGuide(guide) }
        let wide = column.widthAnchor.constraint(equalToConstant: Self.columnWidth)
        wide.priority = .wish
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: Self.columnWidth),
            column.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -2 * Self.margin),
            wide,

            above.topAnchor.constraint(equalTo: view.topAnchor),
            above.bottomAnchor.constraint(equalTo: composerGuide.topAnchor),
            below.topAnchor.constraint(equalTo: composerGuide.topAnchor),
            below.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            above.heightAnchor.constraint(equalTo: below.heightAnchor, multiplier: 0.62),
        ])
    }

    /// Each part against the column alone.
    private func configureColumnConstraints() {
        // The row's line, the controls centred in it.
        let rowLine = NSLayoutGuide()
        column.addLayoutGuide(rowLine)
        // Until a composer is in the slot, a composer's worth — weaker than any
        // view's hugging, so the composer in it keeps its own height.
        let slotHeight = composerGuide.heightAnchor.constraint(equalToConstant: 78)
        slotHeight.priority = .fittingSizeCompression
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: column.topAnchor),
            iconView.centerXAnchor.constraint(equalTo: column.centerXAnchor),

            composerGuide.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 24),
            composerGuide.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            composerGuide.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            slotHeight,

            rowLine.topAnchor.constraint(equalTo: composerGuide.bottomAnchor, constant: Self.rowGap),
            rowLine.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            rowLine.bottomAnchor.constraint(equalTo: column.bottomAnchor),
            controlsRow.centerYAnchor.constraint(equalTo: rowLine.centerYAnchor),
            controlsRow.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: Self.rowInset),
            controlsRow.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor, constant: -Self.rowInset),
            branchButton.widthAnchor.constraint(lessThanOrEqualToConstant: 260),

            // The overlay: hangs under the row, below the column, in no one's way.
            explanationLabel.topAnchor.constraint(equalTo: rowLine.bottomAnchor),
            noteLeading,
            explanationLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: column.trailingAnchor, constant: -Self.rowInset),
        ])
    }

    // MARK: - Showing the model

    /// Shows `content`, configuring the controls in place: a press never
    /// rebuilds what it pressed. Idempotent.
    public func configure(with content: NewSessionContent) {
        self.content = content
        guard isViewLoaded else { return }

        folderButton.show(
            content.folderTitle, font: Self.rowFont, ink: .labelColor, glyph: NSImage.symbol("folder", pointSize: 11))
        folderButton.toolTip = content.folderPath
        alignNoteWithFolderGlyph()
        if menuPopover.isShown, let content = menuContent(for: menuPopover.anchor) {
            menuPopover.configure(with: content)
        }
        explanationLabel.stringValue = content.explanation ?? ""
        explanationLabel.isHidden = (content.explanation ?? "").isEmpty

        switch content.branchRow {
        case .repository(let branchTitle, let usesWorktree):
            branchButton.isHidden = false
            worktreeCheckbox.isHidden = false
            notRepositoryLabel.isHidden = true
            controlsRow.setCustomSpacing(controlsRow.spacing, after: folderButton)
            showBranch(branchTitle)
            showWorktree(usesWorktree)
        case .notARepository(let words):
            branchButton.isHidden = true
            worktreeCheckbox.isHidden = true
            notRepositoryLabel.isHidden = false
            controlsRow.setCustomSpacing(Self.groupGap, after: folderButton)
            notRepositoryLabel.stringValue = words
        case .loading:
            branchButton.isHidden = true
            worktreeCheckbox.isHidden = true
            notRepositoryLabel.isHidden = true
        }
    }

    /// Puts the note's words under the folder's glyph: where the folder's
    /// cell draws its image, less where the label's cell draws its words.
    private func alignNoteWithFolderGlyph() {
        let button = NSRect(origin: .zero, size: folderButton.intrinsicContentSize)
        let glyph = folderButton.cell?.imageRect(forBounds: button).minX ?? 0
        let label = NSRect(origin: .zero, size: explanationLabel.intrinsicContentSize)
        let words = explanationLabel.cell?.titleRect(forBounds: label).minX ?? 0
        noteLeading.constant = glyph - words
    }

    /// The branch glyph and name, 12 pt in secondary ink.
    private func showBranch(_ name: String) {
        let glyph = NSImage.sidebarWorktree.copy() as? NSImage ?? NSImage.sidebarWorktree
        glyph.size = NSSize(width: 10, height: 11)
        branchButton.show(name, font: Self.rowFont, ink: .secondaryLabelColor, glyph: glyph)
    }

    /// The checkbox as the draft has it.
    private func showWorktree(_ isOn: Bool) {
        worktreeCheckbox.state = isOn ? .on : .off
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
        let generation = riseGeneration
        // The animations' own end; a settled rise's ends too, and is let go.
        iconView.rise { [weak self] in
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

    @objc private func showFolderMenu(_ sender: NSButton) {
        open(from: folderButton)
    }

    /// *Choose Folder…* (⌘O, the main menu's, sent up the responder chain):
    /// an open panel for the folder Claude will work in.
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

    @objc private func showBranchMenu(_ sender: NSButton) {
        branchQuery = ""
        open(from: branchButton)
    }

    // MARK: - The menus

    /// What `button`'s menu shows now.
    private func menuContent(for button: NSButton?) -> MenuContent? {
        guard let content else { return nil }
        if button === folderButton { return Self.folderMenu(of: content) }
        if button === branchButton, case .repository = content.branchRow {
            return delegate?.newSessionViewController(self, branchMenuMatching: branchQuery).map(Self.branchMenu)
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
            rows.append(.header(String(localized: "Recent", bundle: .module)))
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
        return MenuContent(rows: rows, minWidth: 320)
    }

    /// The branch's menu (design 08 *The New view*): a search field over the
    /// groups the app lists, 300 wide with 264 of list whatever the search
    /// leaves, the line that says nothing matches in its middle.
    package static func branchMenu(of menu: NewSessionBranchMenu) -> MenuContent {
        let rows: [MenuContent.Row] = menu.rows.map { row in
            switch row {
            case .header(let words):
                .header(words)
            case .item(let item):
                .item(
                    MenuContent.Item(
                        id: item.id, title: item.title, subtitle: item.subtitle, isChecked: item.isChecked,
                        isEnabled: item.isEnabled, toolTip: item.toolTip))
            }
        }
        return MenuContent(
            rows: rows, searchPlaceholder: String(localized: "Filter", bundle: .module), emptyText: menu.emptyText,
            minWidth: 300, listHeight: 264)
    }

    /// Opens `button`'s menu under it, or closes it when it is the one open:
    /// the press that closes it.
    private func open(from button: NSButton) {
        if menuPopover.isShown, menuPopover.anchor === button {
            menuPopover.close()
            return
        }
        guard let content = menuContent(for: button) else { return }
        menuPopover.configure(with: content)
        menuPopover.show(from: button, above: false)
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

    private func branchSearchChanged(_ words: String) {
        branchQuery = words
        if let content = menuContent(for: branchButton) { menuPopover.configure(with: content) }
    }

    /// A press asks for the other choice; the checkbox goes on showing the
    /// draft's, which comes back through `configure(with:)` when the owner
    /// takes it.
    @objc private func toggleWorktree(_ sender: NSControl) {
        delegate?.newSessionViewControllerDidToggleWorktree(self)
        if let content, case .repository(_, let usesWorktree) = content.branchRow { showWorktree(usesWorktree) }
    }
}
