import AppKit
import Combine

/// A scrolling grouped form: sections stacked 30 apart, 20 from the edges,
/// under the toolbar. The scroll view insets itself below the titlebar, as
/// any content under a full-size-content toolbar does.
@MainActor
public final class FormView: NSScrollView {
    /// Whether some of the form is scrolled out below — for a bar under it
    /// to draw its hairline. Called as it changes.
    public var onContentBelowChange: ((Bool) -> Void)?
    private(set) var hasContentBelow = false

    private let stack = NSStackView()
    private let document = FlippedView()
    private var cancellables = Set<AnyCancellable>()

    /// `topInset`: space above the first section.
    public init(sections: [NSView] = [], topInset: CGFloat = 20, sectionSpacing: CGFloat = 30) {
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
        observeContentBelow()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Replaces the sections, each spanning the form's width.
    public func setSections(_ sections: [NSView]) {
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

    /// Scrolling moves the clip's bounds; a section growing moves the
    /// document's frame.
    private func observeContentBelow() {
        contentView.postsBoundsChangedNotifications = true
        document.postsFrameChangedNotifications = true
        Publishers.Merge(
            NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification, object: contentView),
            NotificationCenter.default.publisher(for: NSView.frameDidChangeNotification, object: document)
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.updateContentBelow() }
        .store(in: &cancellables)
    }

    private func updateContentBelow() {
        let below = document.frame.height - contentView.bounds.maxY > 1
        guard below != hasContentBelow else { return }
        hasContentBelow = below
        onContentBelowChange?(below)
    }

    public override func tile() {
        super.tile()
        updateContentBelow()
    }

    /// A document view that lays out from the top, as a form reads.
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}
