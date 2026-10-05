import AppKit
import DisplayModels

/// The composer (design 08 *The composer*): one card — an optional failure
/// section on top, the growing field, the accessory row of Model / Effort /
/// Mode pull-downs, the status slot and the action button — and the slash
/// list over it while a command is being typed. The same controller, the
/// same instance, serves a New tab and the session it becomes: its
/// container moves its view from the New view's middle to the tab's bottom.
///
/// In a page (`ComposerPresentation.Placement`) the key hints sit 12 pt under the
/// card, while the field is empty; floating, the view is the card alone.
///
/// Draws a `ComposerPresentation` (`configure(with:)`) and reports intents to its
/// delegate; it never knows a store. Its own state is only the field's text
/// and the slash list's selection. Keys: ↩ send, ⇧↩ new line, ⇧⇥ the next
/// mode (`ComposerPresentation.cycledModeID`), ⌘. stop, `/` at the start completes a
/// command, backspace into a command token removes it whole.
///
/// Model, Effort and Mode open the popover the New view's pop-ups open too
/// (`MenuPopover`); the slash list is a child panel of its own. Layer corners
/// take the design's radii (`CornerRadius`) with `cornerCurve = .continuous`.
@MainActor
public final class ComposerViewController: NSViewController {
    public weak var delegate: ComposerViewControllerDelegate?

    private let card = ComposerView()
    private var model: ComposerPresentation?
    private let keyHints = NSTextField(labelWithAttributedString: ComposerViewController.hints())
    /// The card, 12, the hints' 16-pt line: in a page.
    private var hintsUnderCard: [NSLayoutConstraint] = []
    /// The card's bottom is the view's: floating.
    private var cardAtBottom: NSLayoutConstraint?

    /// Model's, Effort's or Mode's menu, whichever is open.
    private let menuPopover = MenuPopover()
    private var openControl: ComposerView.Control?

    private lazy var slashList: SlashListViewController = {
        let list = SlashListViewController()
        list.onChoose = { [weak self] command in self?.complete(command) }
        return list
    }()

    private lazy var slashPopup = MenuPopup(contentViewController: slashList, takesKey: false, gap: 8)

    public init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    public override func loadView() {
        view = NSView()
        keyHints.alignment = .center
        keyHints.lineBreakMode = .byTruncatingTail
        keyHints.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for subview in [card, keyHints] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        let hintsLine = NSLayoutGuide()
        view.addLayoutGuide(hintsLine)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: view.topAnchor),
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyHints.centerYAnchor.constraint(equalTo: hintsLine.centerYAnchor),
            keyHints.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            keyHints.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor),
        ])
        hintsUnderCard = [
            hintsLine.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 12),
            hintsLine.heightAnchor.constraint(equalToConstant: 16),
            hintsLine.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ]
        let cardAtBottom = card.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        self.cardAtBottom = cardAtBottom
        cardAtBottom.isActive = true
        keyHints.isHidden = true
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        card.delegate = self
        menuPopover.onChoose = { [weak self] item in self?.menuChose(item) }
        menuPopover.onClose = { [weak self] in self?.menuDidClose() }
    }

    public override func viewDidDisappear() {
        super.viewDidDisappear()
        menuPopover.close()
        slashPopup.close()
    }

    /// Shows `model`. Idempotent.
    public func configure(with model: ComposerPresentation) {
        loadViewIfNeeded()
        let placementChanged = model.placement != self.model?.placement
        self.model = model
        card.configure(with: model)
        if placementChanged { place(model.placement) }
        if menuPopover.isShown, let openControl {
            menuPopover.configure(with: ComposerMenu.content(of: openControl, in: model))
        }
        updateSlashList()
    }

    /// The field's words — read when a New tab closes (they carry to the next
    /// one) and written when a prompt comes back (*Stopped before it was
    /// read*, a cancelled launch).
    public var text: String {
        get { card.text }
        set {
            card.setText(newValue)
            updateKeyHints()
        }
    }

    /// Whether the field's words and token are drawn dimmed — the container's
    /// to set while a sent prompt waits for its session (the handover's first
    /// step). Not the card, the chips or the buttons, and not part of the
    /// `ComposerPresentation`: nothing the session knows.
    public var isFieldDimmed: Bool {
        get { card.isFieldDimmed }
        set { card.isFieldDimmed = newValue }
    }

    /// Gives the field the focus.
    public func focus() {
        card.focus()
    }

    // MARK: - Key hints

    /// The hints under the card in a page; the card alone floating.
    private func place(_ placement: ComposerPresentation.Placement) {
        let inPage = placement == .page
        // One bottom at a time: the old one goes before the new one comes.
        if inPage {
            cardAtBottom?.isActive = false
            NSLayoutConstraint.activate(hintsUnderCard)
        } else {
            NSLayoutConstraint.deactivate(hintsUnderCard)
            cardAtBottom?.isActive = true
        }
        keyHints.isHidden = !inPage
        keyHints.alphaValue = card.text.isEmpty ? 1 : 0
    }

    /// The hints show only while the field is empty: they fade, 0.2 s.
    private func updateKeyHints() {
        let alpha: CGFloat = card.text.isEmpty ? 1 : 0
        guard keyHints.alphaValue != alpha else { return }
        guard !keyHints.isHidden, view.window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            keyHints.alphaValue = alpha
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            keyHints.animator().alphaValue = alpha
        }
    }

    /// `↩ Send   ⇧↩ New Line   ⇧⇥ Mode   / Commands`: the keys in secondary
    /// ink, 3 pt before their words; 14 pt between the hints.
    private static func hints() -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 11)
        let pairs = [
            ("↩", String(localized: "Send", bundle: .module)),
            ("⇧↩", String(localized: "New Line", bundle: .module)),
            ("⇧⇥", String(localized: "Mode", bundle: .module)),
            ("/", String(localized: "Commands", bundle: .module)),
        ]
        // A zero-width joiner carries each gap as its kerning, so the gap is exact.
        let joiner = "\u{200D}"
        let text = NSMutableAttributedString()
        for (index, (key, words)) in pairs.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: joiner, attributes: [.font: font, .kern: 14])) }
            text.append(
                NSAttributedString(
                    string: key, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            text.append(NSAttributedString(string: joiner, attributes: [.font: font, .kern: 3]))
            text.append(
                NSAttributedString(
                    string: words, attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        return text
    }

    // MARK: - Menus

    /// Opens `control`'s menu — under its button in a page, over it floating
    /// — or closes it when it is the one open: the press that closes it.
    private func openMenu(of control: ComposerView.Control) {
        guard let model else { return }
        if menuPopover.isShown, openControl == control {
            menuPopover.close()
            return
        }
        menuPopover.configure(with: ComposerMenu.content(of: control, in: model))
        card.showMenu(of: control, in: menuPopover, above: model.placement != .page)
        openControl = menuPopover.isShown ? control : nil
    }

    private func menuChose(_ item: MenuContent.Item) {
        guard let choice = item.id as? ComposerMenu.Choice else { return }
        switch choice {
        case .item(let id):
            delegate?.composerViewController(self, didChoose: id)
        case .fastMode:
            guard case .toggle(let isOn) = item.trailing else { return }
            delegate?.composerViewController(self, didSetFastMode: !isOn)
        }
    }

    private func menuDidClose() {
        openControl = nil
    }

    // MARK: - Slash commands

    /// Opens, filters or closes the list to match what the field holds.
    private func updateSlashList() {
        guard let model, let window = view.window, let query = card.slashQuery else {
            slashPopup.close()
            return
        }
        let matches = model.commands.filter { $0.name.lowercased().hasPrefix(query.lowercased()) }
        guard !matches.isEmpty else {
            slashPopup.close()
            return
        }
        let frame = card.cardFrame
        slashList.configure(commands: matches, width: frame.width)
        let anchor = window.convertToScreen(card.convert(frame, to: nil))
        let size = slashList.preferredSize
        if slashPopup.isShown {
            slashPopup.move(to: anchor, size: size, in: window)
        } else {
            slashPopup.show(
                at: anchor, preferring: model.placement == .page ? .below : .above, in: window, size: size,
                makingKey: false)
        }
    }

    private func complete(_ command: ComposerPresentation.Command) {
        slashPopup.close()
        card.complete(command: command.name)
        card.focus()
    }
}

extension ComposerViewController: ComposerViewDelegate {
    func composerView(_ composerView: ComposerView, didSubmit text: String) {
        slashPopup.close()
        delegate?.composerViewController(self, didSubmit: text)
    }

    func composerViewDidRequestStop(_ composerView: ComposerView) {
        delegate?.composerViewControllerDidRequestStop(self)
    }

    func composerView(_ composerView: ComposerView, didPress control: ComposerView.Control) {
        openMenu(of: control)
    }

    func composerViewDidRequestRestart(_ composerView: ComposerView) {
        delegate?.composerViewControllerDidRequestRestart(self)
    }

    func composerViewDidRequestLog(_ composerView: ComposerView) {
        delegate?.composerViewControllerDidRequestLog(self)
    }

    func composerViewDidRequestWaitingRequest(_ composerView: ComposerView) {
        delegate?.composerViewControllerDidRequestWaitingRequest(self)
    }

    func composerViewDidRequestContextUsage(_ composerView: ComposerView) {
        delegate?.composerViewControllerDidRequestContextUsage(self)
    }

    func composerViewDidChangeText(_ composerView: ComposerView) {
        updateSlashList()
        updateKeyHints()
    }

    func composerView(_ composerView: ComposerView, handle key: ComposerFieldView.Key) -> Bool {
        switch key {
        case .send, .tab:
            // Completes the command the list is on.
            guard slashPopup.isShown, let command = slashList.selectedCommand else { return false }
            complete(command)
            return true
        case .moveUp:
            guard slashPopup.isShown else { return false }
            slashList.moveSelection(-1)
            return true
        case .moveDown:
            guard slashPopup.isShown else { return false }
            slashList.moveSelection(1)
            return true
        case .backtab:
            if let id = model?.cycledModeID {
                delegate?.composerViewController(self, didChoose: id)
            }
            return true
        case .escape:
            guard slashPopup.isShown else { return false }
            slashPopup.close()
            return true
        }
    }
}
