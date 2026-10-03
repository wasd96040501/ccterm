import AgentSDK
import AppKit

/// The composer (design 08 *The composer*): one card — an optional failure
/// section on top, the growing field, the accessory row of Model / Effort /
/// Mode pull-downs, the status slot and the action button — and the slash
/// list over it while a command is being typed. The same controller, the
/// same instance, serves a New tab and the session it becomes: its
/// container moves its view from the New view's middle to the tab's bottom.
///
/// Draws a `ComposerModel` (`configure(with:)`) and reports intents to its
/// delegate; it never knows a store. Its own state is only the field's text
/// and the slash list's selection. Keys: ↩ send, ⇧↩ new line, ⇧⇥ the next
/// mode (`ComposerModel.cycledMode`), ⌘. stop, `/` at the start completes a
/// command, backspace into a command token removes it whole.
///
/// Model, Effort and Mode open the one menu the New view's pop-ups open too
/// (`MenuPanel`); the slash list is a child panel of its own. Layer corners
/// take the design's radii (`CornerRadius`) with `cornerCurve = .continuous`.
@MainActor
final class ComposerViewController: NSViewController {
    weak var delegate: ComposerViewControllerDelegate?

    private let card = ComposerView()
    private var model: ComposerModel?

    /// Model, Effort or Mode, whichever is open — one menu at a time.
    private let popUpMenu = MenuPanel()
    private var openControl: ComposerView.Control?
    /// The model panel's account sections unfolded past *N More Models*.
    private var expandedSections: Set<UUID> = []
    /// The menu that closed last and when: the press on its chip that took
    /// the keyboard from it closes it, and the chip's action must not reopen it.
    private var lastClosed: (control: ComposerView.Control, at: TimeInterval)?

    private lazy var slashList: SlashListViewController = {
        let list = SlashListViewController()
        list.onChoose = { [weak self] command in self?.complete(command) }
        return list
    }()

    private lazy var slashPopup = MenuPopup(contentViewController: slashList, takesKey: false, gap: 8)

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        view = card
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        card.delegate = self
        popUpMenu.onChoose = { [weak self] item in self?.menuChose(item) }
        popUpMenu.onClose = { [weak self] in self?.menuDidClose() }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        popUpMenu.close()
        slashPopup.close()
    }

    /// Shows `model`. Idempotent.
    func configure(with model: ComposerModel) {
        self.model = model
        card.configure(with: model)
        if popUpMenu.isShown, let openControl { popUpMenu.update(content(of: openControl, in: model)) }
        updateSlashList()
    }

    /// The field's words — read when a New tab closes (they carry to the next
    /// one) and written when a prompt comes back (*Stopped before it was
    /// read*, a cancelled launch).
    var text: String {
        get { card.text }
        set { card.setText(newValue) }
    }

    /// Whether the field's words and token are drawn dimmed — the container's
    /// to set while a sent prompt waits for its session (the handover's first
    /// step). Not the card, the chips or the buttons, and not part of the
    /// `ComposerModel`: nothing the session knows.
    var isFieldDimmed: Bool {
        get { card.isFieldDimmed }
        set { card.isFieldDimmed = newValue }
    }

    /// Gives the field the focus.
    func focus() {
        card.focus()
    }

    // MARK: - Menus

    private func content(of control: ComposerView.Control, in model: ComposerModel) -> MenuContent {
        switch control {
        case .model: ComposerMenu.modelContent(of: model, expanded: expandedSections)
        case .effort: ComposerMenu.content(of: model.effortMenu)
        case .mode: ComposerMenu.content(of: model.modeMenu)
        }
    }

    /// Opens `control`'s menu — under the chip in a New tab, over it in a
    /// session — or closes it when it is the one open.
    private func openMenu(of control: ComposerView.Control) {
        guard let model else { return }
        let wasOpen = openControl
        popUpMenu.close()
        guard wasOpen != control else { return }
        if let lastClosed, lastClosed.control == control,
            ProcessInfo.processInfo.systemUptime - lastClosed.at < 0.5
        {
            return
        }
        let content = content(of: control, in: model)
        guard !content.rows.isEmpty else { return }
        let chip = card.chip(for: control)
        openControl = control
        chip.isOpen = true
        popUpMenu.show(content, from: chip, preferring: model.isDraft ? .below : .above)
    }

    private func menuChose(_ item: MenuContent.Item) {
        guard let choice = item.id as? ComposerMenu.Choice else { return }
        switch choice {
        case .change(let change):
            delegate?.composerViewController(self, didChoose: change)
        case .more(let section):
            // Expands in place: the panel stays open and its list stays put.
            expandedSections.insert(section)
            if let model, let openControl { popUpMenu.update(content(of: openControl, in: model)) }
        case .fastMode:
            guard case .toggle(let isOn) = item.trailing else { return }
            delegate?.composerViewController(self, didChoose: .fastMode(!isOn))
        }
    }

    private func menuDidClose() {
        if let openControl {
            card.chip(for: openControl).isOpen = false
            lastClosed = (openControl, ProcessInfo.processInfo.systemUptime)
        }
        openControl = nil
        view.window?.makeKey()
        card.focus()
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
                at: anchor, preferring: model.isDraft ? .below : .above, in: window, size: size, makingKey: false)
        }
    }

    private func complete(_ command: SlashCommand) {
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
        delegate?.composerViewControllerDidChangeText(self)
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
            if let change = model?.cycledMode {
                delegate?.composerViewController(self, didChoose: change)
            }
            return true
        case .escape:
            guard slashPopup.isShown else { return false }
            slashPopup.close()
            return true
        case .stop:
            if model?.action == .stop { delegate?.composerViewControllerDidRequestStop(self) }
            return true
        }
    }
}
