import AppKit

/// A document's body when there is nothing to show: one line of tertiary
/// words centred on the page (*This document is no longer in the
/// transcript.*), worded by the app. The page is the text background, as the
/// command and source bodies' are.
@MainActor
public final class DocumentNoteViewController: NSViewController {
    private let text: String

    public init(_ text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    public override func loadView() {
        view = PageView()
        let label = NSTextField(labelWithString: text)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private final class PageView: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        }
    }
}
