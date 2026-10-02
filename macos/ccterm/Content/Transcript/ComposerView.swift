import AppKit

/// Where the reader writes to a session, under its transcript: a growing
/// text field and one button — *Send*, or *Stop* while a turn runs. Return
/// sends, Shift-Return breaks the line. Reports through its delegate only;
/// what sending does is the tab's.
@MainActor
final class ComposerView: NSView {
    weak var delegate: ComposerViewDelegate?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // TODO(live): the field and the button (`PillButton`), Auto Layout,
        // height following the text up to a cap.
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Shows *Stop* while `isResponding`, *Send* otherwise. Idempotent.
    func configure(isResponding: Bool) {
        // TODO(live)
    }

    /// Gives the field the focus: a new session opens ready to type.
    func focus() {
        // TODO(live)
    }
}
