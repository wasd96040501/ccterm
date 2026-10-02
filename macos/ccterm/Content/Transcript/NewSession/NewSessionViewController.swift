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

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        // TODO(fill D): hero, folder pop-up, branch row, explanation, hints.
        let view = NSView()
        view.addLayoutGuide(composerGuide)
        NSLayoutConstraint.activate([
            composerGuide.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            composerGuide.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            composerGuide.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
            composerGuide.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32),
        ])
        let fill = composerGuide.widthAnchor.constraint(equalToConstant: 640)
        fill.priority = .defaultHigh
        fill.isActive = true
        self.view = view
    }

    /// Shows `model`. Idempotent.
    func configure(with model: NewSessionModel) {
        self.model = model
        // TODO(fill D)
    }

    /// Whether the key hints show — only while the field is empty.
    func setHintsVisible(_ visible: Bool) {
        // TODO(fill D)
    }

    /// Plays Send's rise and calls `completion` when it ends (at once under
    /// Reduce Motion). The field's words stay, dimmed, until then — the
    /// container's to dim.
    func rise(completion: @escaping @MainActor () -> Void) {
        // TODO(fill D)
        completion()
    }
}
