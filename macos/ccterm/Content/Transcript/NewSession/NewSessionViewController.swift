import AppKit

/// The New view (design 08): centred a third of the way down — the app icon
/// at 64 pt over its still glow, the folder as a 22-pt pop-up title with its
/// path under it, the branch pop-up and the Worktree toggle on one row that
/// never moves, the line that says what Send will do, then a slot for the
/// composer (640 pt) and the key hints under it.
///
/// The composer is not this view's: its container pins the composer's view to
/// `composerGuide`, and moves it out when the tab hands over. This view only
/// keeps the slot the composer's height and width, so the hints sit under it.
///
/// Send's one motion is `rise(completion:)`: 600 ms, the icon's cursor lit
/// row by row from the bottom while the glow swells (design 08 *Send is the one
/// moment it moves*); Reduce Motion skips it. In Dark it draws the icon's
/// Dark rendition.
@MainActor
final class NewSessionViewController: NSViewController {
    weak var delegate: NewSessionViewControllerDelegate?

    /// Where the composer goes: 640 pt wide at most, centred, under the
    /// explanation line. The container sets its height to the composer's.
    let composerGuide = NSLayoutGuide()

    private var model: NewSessionModel?
    private let prefersReducedMotion: () -> Bool
    private var riseCompletions: [@MainActor () -> Void] = []
    private var isRising = false
    /// Which rise is playing; a rise that was settled finds its timer stale.
    private var riseGeneration = 0
    private var branchPopover: NSPopover?

    private let iconView = NewSessionIconView()

    private lazy var folderChip: NewSessionChip = {
        let chip = NewSessionChip(title: String(localized: "Choose Folder…"), look: .folder)
        chip.setAccessibilityIdentifier("newSession.folder")
        chip.setAccessibilityRole(.popUpButton)
        return chip
    }()

    private lazy var pathLabel = Self.label(size: 11, color: .tertiaryLabelColor)

    private lazy var branchChip: NewSessionChip = {
        let chip = NewSessionChip(title: "", look: .row)
        // The design's branch glyph, 10 × 11 on the pop-up.
        let glyph = NSImage(resource: .sidebarWorktree)
        glyph.size = NSSize(width: 10, height: 11)
        chip.glyph = glyph
        chip.toolTip = String(localized: "Branch")
        chip.target = self
        chip.action = #selector(showBranchPicker(_:))
        chip.setAccessibilityIdentifier("newSession.branch")
        chip.setAccessibilityRole(.popUpButton)
        return chip
    }()

    private lazy var worktreeChip: NewSessionChip = {
        let chip = NewSessionChip(title: String(localized: "Worktree"), look: .row, showsChevron: false)
        chip.glyph = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: nil)
        chip.toolTip = String(
            localized: "Work in a new git worktree (--worktree), leaving this folder as it is")
        chip.target = self
        chip.action = #selector(toggleWorktree(_:))
        chip.setAccessibilityIdentifier("newSession.worktree")
        chip.setAccessibilityRole(.checkBox)
        return chip
    }()

    private lazy var notRepositoryLabel = Self.label(size: 12, color: .tertiaryLabelColor)
    private lazy var explanationLabel = Self.label(size: 11, color: .tertiaryLabelColor)
    private lazy var hintsLabel: NSTextField = {
        let label = Self.label(size: 11, color: .tertiaryLabelColor)
        label.attributedStringValue = Self.hints()
        return label
    }()

    private lazy var whereRow: NSView = {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }()

    /// `prefersReducedMotion` is the system's Reduce Motion setting; the rise
    /// is skipped under it.
    init(
        prefersReducedMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    ) {
        self.prefersReducedMotion = prefersReducedMotion
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        view = NewSessionRootView { [weak self] in self?.chooseFolder(nil) }
        configureHierarchy()
        configureConstraints()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let model { configure(with: model) }
    }

    // MARK: - Tree

    private func configureHierarchy() {
        for subview in [iconView, folderChip, pathLabel, whereRow, explanationLabel, hintsLabel] {
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
        view.addLayoutGuide(above)
        view.addLayoutGuide(below)

        // Until a composer is in the slot, a composer's worth — weaker than any
        // view's hugging, so the composer in it keeps its own height.
        let slotHeight = composerGuide.heightAnchor.constraint(equalToConstant: 100)
        slotHeight.priority = .fittingSizeCompression
        let slotWidth = composerGuide.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -32)
        slotWidth.priority = .wishUnderWindowSize

        NSLayoutConstraint.activate([
            above.topAnchor.constraint(equalTo: view.topAnchor),
            above.heightAnchor.constraint(equalTo: below.heightAnchor, multiplier: 0.62),
            iconView.topAnchor.constraint(equalTo: above.bottomAnchor),
            hintsLabel.bottomAnchor.constraint(equalTo: below.topAnchor),
            below.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            iconView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            folderChip.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 16),
            folderChip.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            folderChip.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -48),
            pathLabel.topAnchor.constraint(equalTo: folderChip.bottomAnchor, constant: 2),
            pathLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pathLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -48),
            whereRow.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 8),
            whereRow.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            whereRow.heightAnchor.constraint(equalToConstant: 24),
            whereRow.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -48),
            explanationLabel.topAnchor.constraint(equalTo: whereRow.bottomAnchor, constant: 2),
            explanationLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            explanationLabel.heightAnchor.constraint(equalToConstant: 15),
            explanationLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -48),

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

            composerGuide.topAnchor.constraint(equalTo: explanationLabel.bottomAnchor, constant: 20),
            composerGuide.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            composerGuide.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
            composerGuide.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32),
            slotWidth,
            slotHeight,
            hintsLabel.topAnchor.constraint(equalTo: composerGuide.bottomAnchor, constant: 12),
            hintsLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 16),
            hintsLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hintsLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32),
        ])
    }

    // MARK: - Showing the model

    /// Shows `model`. Idempotent.
    func configure(with model: NewSessionModel) {
        self.model = model
        guard isViewLoaded else { return }

        folderChip.title = model.folderTitle
        folderChip.menu = folderMenu(for: model)
        pathLabel.stringValue = model.folderPath ?? ""
        explanationLabel.stringValue = model.explanation ?? ""

        switch model.branchRow {
        case .repository(let branchTitle, let usesWorktree, _):
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

    /// Whether the key hints show — only while the field is empty.
    func setHintsVisible(_ visible: Bool) {
        let alpha: CGFloat = visible ? 1 : 0
        guard hintsLabel.alphaValue != alpha else { return }
        guard view.window != nil, !prefersReducedMotion() else {
            hintsLabel.alphaValue = alpha
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            hintsLabel.animator().alphaValue = alpha
        }
    }

    /// Plays Send's rise and calls `completion` when it ends (at once under
    /// Reduce Motion). The field's words stay, dimmed, until then — the
    /// container's to dim.
    func rise(completion: @escaping @MainActor () -> Void) {
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
    func settleRise() {
        guard isRising else { return }
        riseGeneration += 1
        isRising = false
        riseCompletions = []
        iconView.settle()
    }

    // MARK: - The folder

    private func folderMenu(for model: NewSessionModel) -> NSMenu {
        let menu = NSMenu()
        if !model.recentFolders.isEmpty {
            menu.addItem(NSMenuItem.sectionHeader(title: String(localized: "Recent")))
            for folder in model.recentFolders {
                let item = NSMenuItem(title: folder.title, action: #selector(chooseRecent(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = folder.url
                item.state = folder.isChosen ? .on : .off
                item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                item.toolTip = (folder.url.path as NSString).abbreviatingWithTildeInPath
                if #available(macOS 14.4, *) {
                    item.subtitle =
                        (folder.url.deletingLastPathComponent().path as NSString)
                        .abbreviatingWithTildeInPath
                }
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        let choose = NSMenuItem(
            title: String(localized: "Choose Folder…"), action: #selector(chooseFolder(_:)), keyEquivalent: "o")
        choose.keyEquivalentModifierMask = .command
        choose.target = self
        menu.addItem(choose)
        return menu
    }

    @objc private func chooseRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        delegate?.newSessionViewController(self, didChooseFolder: url)
    }

    /// *Choose Folder…* (⌘O): an open panel for the folder Claude will work in.
    @objc private func chooseFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose the folder Claude will work in.")
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
        guard case .repository(_, _, let branches)? = model?.branchRow else { return }
        branchPopover?.close()

        let picker = BranchPickerViewController(model: BranchPickerModel(branches))
        picker.onChoose = { [weak self] branch in
            guard let self else { return }
            branchPopover?.close()
            delegate?.newSessionViewController(self, didChooseBranch: branch)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = picker
        popover.delegate = self
        branchPopover = popover
        branchChip.isOpen = true
        popover.show(relativeTo: branchChip.bounds, of: branchChip, preferredEdge: .minY)
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

    /// `↩ Send   ⇧↩ New Line   ⇧⇥ Mode   / Commands`: the keys in secondary ink.
    private static func hints() -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 11)
        let pairs = [
            ("↩", String(localized: "Send")),
            ("⇧↩", String(localized: "New Line")),
            ("⇧⇥", String(localized: "Mode")),
            ("/", String(localized: "Commands")),
        ]
        let text = NSMutableAttributedString()
        for (index, (key, words)) in pairs.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "\u{2003}\u{2002}", attributes: [.font: font])) }
            text.append(
                NSAttributedString(
                    string: key + " ", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            text.append(
                NSAttributedString(
                    string: words, attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        return text
    }
}

extension NewSessionViewController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        branchChip.isOpen = false
        branchPopover = nil
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
