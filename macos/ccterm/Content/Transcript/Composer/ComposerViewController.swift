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
/// Built from AppKit's own pieces: borderless pull-down `NSPopUpButton`s
/// with `NSMenu` (section headers, item subtitles) for Effort and Mode; the
/// model panel (`ModelPanelController`, a child panel with a table whose group
/// rows float, and an `NSSwitch`); layer corners with
/// `cornerCurve = .continuous` at the design's radii.
@MainActor
final class ComposerViewController: NSViewController {
    weak var delegate: ComposerViewControllerDelegate?

    // TODO(fill C): the card, chips, panel, slash list, banner. The field below
    // is the previous composer, kept so a session tab works meanwhile.
    private let field = ComposerView()
    private var model: ComposerModel?

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        view = field
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        field.delegate = self
    }

    /// Shows `model`. Idempotent.
    func configure(with model: ComposerModel) {
        self.model = model
        field.configure(isResponding: model.action == .stop)
    }

    /// The field's words — read when a New tab closes (they carry to the next
    /// one) and written when a prompt comes back (*Stopped before it was
    /// read*, a cancelled launch).
    var text: String {
        get { field.text }
        set { field.text = newValue }
    }

    /// Gives the field the focus.
    func focus() {
        field.focus()
    }

    /// The card's height as laid out — the transcript keeps this much (plus
    /// the 16-pt float) clear under its last row.
    var cardHeight: CGFloat {
        // TODO(fill C)
        view.fittingSize.height
    }
}

extension ComposerViewController: ComposerViewDelegate {
    func composerView(_ composerView: ComposerView, didSubmit text: String) {
        delegate?.composerViewController(self, didSubmit: text)
    }

    func composerViewDidRequestStop(_ composerView: ComposerView) {
        delegate?.composerViewControllerDidRequestStop(self)
    }
}
