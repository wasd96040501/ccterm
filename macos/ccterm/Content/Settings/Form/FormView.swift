import AppKit

/// A scrolling grouped form: sections stacked 30 apart, 20 from the edges,
/// under the toolbar. The scroll view insets itself below the titlebar, as
/// any content under a full-size-content toolbar does.
@MainActor
final class FormView: NSScrollView {
    private let stack = NSStackView()
    private let document = FlippedView()

    /// `topInset`: space above the first section.
    init(sections: [NSView] = [], topInset: CGFloat = 20, sectionSpacing: CGFloat = 30) {
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = sectionSpacing
        stack.edgeInsets = NSEdgeInsets(top: topInset, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        documentView = document
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
        ])
        setSections(sections)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Replaces the sections, each spanning the form's width.
    func setSections(_ sections: [NSView]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for section in sections {
            section.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
    }

    /// A document view that lays out from the top, as a form reads.
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}
