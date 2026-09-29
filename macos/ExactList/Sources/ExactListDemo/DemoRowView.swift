import AppKit

/// One demo row: a block of wrapped text on a rounded card, with a disclosure
/// that expands it. Its height comes from `height(for:width:)`, from the same
/// constants its layout uses.
final class DemoRowView: NSView {

    /// Reports a press on the disclosure: the host toggles its model and
    /// commits anchored on this row (A2).
    var onToggle: (() -> Void)?

    override init(frame frameRect: NSRect) {
        fatalError("unimplemented: demo")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    static func height(for text: String, expanded: Bool, width: CGFloat) -> CGFloat {
        fatalError("unimplemented: demo")
    }

    func configure(text: String, expanded: Bool) {
        fatalError("unimplemented: demo")
    }
}
