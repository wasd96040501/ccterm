import AppKit

/// A host that holds its content at a fixed size, centred in the card: for a
/// component whose host is not a window the style page can draw yet.
final class CentredHost: NSView, ControllerHost {
    /// What owns the content, kept as long as the host is.
    private let owner: AnyObject?

    /// The owner, when it is a view controller; a popover keeps its own.
    var controllers: [NSViewController] { [owner as? NSViewController].compactMap { $0 } }

    init(_ content: NSView, size: NSSize, owner: AnyObject? = nil) {
        self.owner = owner
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: size.width),
            content.heightAnchor.constraint(equalToConstant: size.height),
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}
