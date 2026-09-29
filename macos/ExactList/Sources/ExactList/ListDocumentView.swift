import AppKit

/// The flipped document view: row containers are its subviews. It is the first
/// responder and the accessibility table (SPEC K1, X1), and it answers AppKit's
/// overdraw request (P1).
///
/// Its size is `W × H` (G2), and only the list sets it.
final class ListDocumentView: NSView {

    /// Weak: the list owns this view.
    weak var owner: ListDocumentViewOwner?

    /// The key being interpreted, so one the list doesn't answer can go up the
    /// chain as the event itself, and an input method further up composes it.
    private var interpretedKey: NSEvent?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var isFlipped: Bool { true }

    // MARK: - Responder (K1)

    override var acceptsFirstResponder: Bool {
        true
    }

    /// A click that no row consumed takes focus, as in `NSTableView`, then goes
    /// up the chain.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        interpretedKey = event
        defer { interpretedKey = nil }
        interpretKeyEvents([event])
    }

    override func doCommand(by selector: Selector) {
        if owner?.documentView(self, doCommandBy: selector) == true { return }
        passInterpretedKeyUp()
    }

    override func insertText(_ insertString: Any) {
        passInterpretedKeyUp()
    }

    private func passInterpretedKeyUp() {
        guard let interpretedKey else { return }
        nextResponder?.keyDown(with: interpretedKey)
    }

    // MARK: - Responsive scrolling (P1)

    override func prepareContent(in rect: NSRect) {
        super.prepareContent(in: rect)
        owner?.documentView(self, prepareContentIn: rect)
    }

    // MARK: - Accessibility table (X1)

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .table
    }

    override func accessibilityRows() -> [Any]? {
        guard let owner else { return [] }
        return (0..<owner.numberOfAccessibilityRows(in: self)).map {
            owner.documentView(self, accessibilityRowAt: $0)
        }
    }

    override func accessibilityRowCount() -> Int {
        owner?.numberOfAccessibilityRows(in: self) ?? 0
    }

    override func accessibilityVisibleRows() -> [Any]? {
        guard let owner else { return [] }
        return owner.accessibilityVisibleRows(in: self).map { owner.documentView(self, accessibilityRowAt: $0) }
    }

    override func accessibilityChildren() -> [Any]? {
        accessibilityRows()
    }
}
