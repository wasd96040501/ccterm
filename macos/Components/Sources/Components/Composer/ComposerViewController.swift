import AppKit
import DisplayModels

/// The composer (design 08 *The composer*): one card — an optional failure
/// section on top, the growing field, the accessory row of Model / Effort /
/// Mode pull-downs, the status slot and the action button — and the slash
/// list over it while a command is being typed. The same controller, the
/// same instance, serves a New tab and the session it becomes: its
/// container moves its view from the New view's middle to the tab's bottom.
///
/// The view is the card; where it stands (`ComposerPresentation.Placement`)
/// decides only which way its menus and completion open.
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
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: view.topAnchor),
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
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
        self.model = model
        card.configure(with: model)
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
        set { card.setText(newValue) }
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
