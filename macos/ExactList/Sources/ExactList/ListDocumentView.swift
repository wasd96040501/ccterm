import AppKit

/// The flipped document view: row containers are its subviews. It is the first
/// responder and the accessibility table (SPEC K1, X1), and it answers AppKit's
/// overdraw request (P1).
///
/// Its size is `W × H` (G2), and only the list sets it.
final class ListDocumentView: NSView {

    /// Weak: the list owns this view.
    weak var owner: ListDocumentViewOwner?

    override init(frame frameRect: NSRect) {
        fatalError("unimplemented: SPEC K1")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var isFlipped: Bool { true }

    // MARK: - Responder (K1)

    override var acceptsFirstResponder: Bool {
        fatalError("unimplemented: SPEC K1")
    }

    /// A click that no row consumed takes focus, as in `NSTableView`, then goes
    /// up the chain.
    override func mouseDown(with event: NSEvent) {
        fatalError("unimplemented: SPEC K1")
    }

    override func keyDown(with event: NSEvent) {
        fatalError("unimplemented: SPEC K1")
    }

    override func doCommand(by selector: Selector) {
        fatalError("unimplemented: SPEC K1")
    }

    override func insertText(_ insertString: Any) {
        fatalError("unimplemented: SPEC K1")
    }

    // MARK: - Responsive scrolling (P1)

    override func prepareContent(in rect: NSRect) {
        fatalError("unimplemented: SPEC P1")
    }

    // MARK: - Accessibility table (X1)

    override func isAccessibilityElement() -> Bool {
        fatalError("unimplemented: SPEC X1")
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        fatalError("unimplemented: SPEC X1")
    }

    override func accessibilityRows() -> [Any]? {
        fatalError("unimplemented: SPEC X1")
    }

    override func accessibilityRowCount() -> Int {
        fatalError("unimplemented: SPEC X1")
    }

    override func accessibilityVisibleRows() -> [Any]? {
        fatalError("unimplemented: SPEC X1")
    }

    override func accessibilityChildren() -> [Any]? {
        fatalError("unimplemented: SPEC X1")
    }
}
