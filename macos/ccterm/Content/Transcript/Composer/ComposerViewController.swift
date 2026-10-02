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
/// Built from AppKit's own pieces: `NSMenu`s (section headers, item
/// subtitles) for Effort and Mode; the model panel (`ModelPanelViewController`
/// in a child panel: a table whose group rows float, and an `NSSwitch`); the
/// slash list, a child panel too; layer corners with `cornerCurve =
/// .continuous` at the design's radii.
@MainActor
final class ComposerViewController: NSViewController {
    weak var delegate: ComposerViewControllerDelegate?

    private let card = ComposerView()
    private var model: ComposerModel?

    private lazy var modelPanel: ModelPanelViewController = {
        let panel = ModelPanelViewController()
        panel.onChoose = { [weak self] item in
            guard let self else { return }
            self.closeModelPanel(restoringFocus: true)
            self.delegate?.composerViewController(self, didChoose: item.change)
        }
        panel.onSetFast = { [weak self] isOn in
            guard let self else { return }
            self.delegate?.composerViewController(self, didChoose: .fastMode(isOn))
        }
        panel.onCancel = { [weak self] in self?.closeModelPanel(restoringFocus: true) }
        panel.onHeightChange = { [weak self] in
            guard let self else { return }
            self.modelPopup.resize(
                to: NSSize(width: ModelPanelViewController.width, height: self.modelPanel.preferredHeight))
        }
        return panel
    }()

    private lazy var modelPopup: ComposerPopup = {
        let popup = ComposerPopup(contentViewController: modelPanel, takesKey: true, gap: 4)
        popup.onClose = { [weak self] in self?.card.chip(for: .model).isOpen = false }
        return popup
    }()

    private lazy var slashList: SlashListViewController = {
        let list = SlashListViewController()
        list.onChoose = { [weak self] command in self?.complete(command) }
        return list
    }()

    private lazy var slashPopup = ComposerPopup(contentViewController: slashList, takesKey: false, gap: 8)

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
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        closeModelPanel(restoringFocus: false)
        slashPopup.close()
    }

    /// Shows `model`. Idempotent.
    func configure(with model: ComposerModel) {
        self.model = model
        card.configure(with: model)
        if modelPopup.isShown { modelPanel.configure(with: model) }
        updateSlashList()
    }

    /// The field's words — read when a New tab closes (they carry to the next
    /// one) and written when a prompt comes back (*Stopped before it was
    /// read*, a cancelled launch).
    var text: String {
        get { card.text }
        set { card.setText(newValue) }
    }

    /// Gives the field the focus.
    func focus() {
        card.focus()
    }

    /// The card's height as laid out — the transcript keeps this much (plus
    /// the 16-pt float) clear under its last row.
    var cardHeight: CGFloat {
        view.layoutSubtreeIfNeeded()
        return view.fittingSize.height
    }

    // MARK: - Menus and the panel

    @objc private func menuItemChosen(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ComposerMenu.Choice else { return }
        delegate?.composerViewController(self, didChoose: choice.change)
    }

    private func popUp(_ menu: ComposerModel.Menu, from control: ComposerView.Control) {
        guard !menu.sections.isEmpty else { return }
        let nsMenu = ComposerMenu.make(menu, target: self, action: #selector(menuItemChosen(_:)))
        let chip = card.chip(for: control)
        let isDraft = model?.isDraft ?? false
        // The menu hangs its top-left from the point: above the chip, that is
        // the chip's top plus the menu's height.
        let point =
            isDraft
            ? NSPoint(x: -4, y: -4)
            : NSPoint(x: -4, y: chip.bounds.height + 4 + nsMenu.size.height)
        chip.isOpen = true
        nsMenu.popUp(positioning: nil, at: point, in: chip)
        chip.isOpen = false
        card.focus()
    }

    private func openModelPanel() {
        guard let model, let window = view.window else { return }
        if modelPopup.isShown {
            closeModelPanel(restoringFocus: true)
            return
        }
        let chip = card.chip(for: .model)
        modelPanel.configure(with: model)
        modelPanel.selectCurrent()
        let anchor = window.convertToScreen(chip.convert(chip.bounds, to: nil))
        modelPopup.show(
            at: anchor, preferring: model.isDraft ? .below : .above, in: window,
            size: NSSize(width: ModelPanelViewController.width, height: modelPanel.preferredHeight), makingKey: true)
        modelPopup.makeFirstResponder(modelPanel.initialFirstResponder)
        chip.isOpen = true
    }

    private func closeModelPanel(restoringFocus: Bool) {
        guard modelPopup.isShown else { return }
        modelPopup.close()
        if restoringFocus {
            view.window?.makeKey()
            card.focus()
        }
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
        guard let model else { return }
        switch control {
        case .model: openModelPanel()
        case .effort: popUp(model.effortMenu, from: .effort)
        case .mode: popUp(model.modeMenu, from: .mode)
        }
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
