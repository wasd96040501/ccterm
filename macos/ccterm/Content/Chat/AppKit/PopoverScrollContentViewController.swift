import AppKit

/// Base popover content view controller: an `NSScrollView` wrapping a vertical
/// `NSStackView` document view, sized to a fixed `width` with a `maxHeight` cap
/// (content collapses below the cap; past it the inner scroller takes over) —
/// the AppKit analogue of SwiftUI `ScrollView { VStack }.frame(width:
/// maxHeight:)` (migration plan §4.2 appkitMapping). Used by the permission /
/// model+effort / context / background-task / todo popover bodies.
///
/// The `documentStack` is the row container; subclasses (or callers) fill it
/// via `populate(_:)`. `outerPadding` mirrors `PopoverList.outerPadding` (6)
/// for the chrome popovers; the breakdown / task / todo bodies pass their own.
@MainActor
class PopoverScrollContentViewController: NSViewController {

    let width: CGFloat
    let maxHeight: CGFloat
    let outerPadding: CGFloat
    let documentStackSpacing: CGFloat

    /// The vertical row container the popover content fills.
    let documentStack = NSStackView()

    private let scrollView = NSScrollView()
    private let flippedDocument = PopoverFlippedClipView()

    init(
        width: CGFloat,
        maxHeight: CGFloat = PopoverListMetrics.maxHeight,
        outerPadding: CGFloat = PopoverListMetrics.outerPadding,
        documentStackSpacing: CGFloat = 0
    ) {
        self.width = width
        self.maxHeight = maxHeight
        self.outerPadding = outerPadding
        self.documentStackSpacing = documentStackSpacing
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    nonisolated deinit {}

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()

        flippedDocument.translatesAutoresizingMaskIntoConstraints = false

        documentStack.orientation = .vertical
        documentStack.alignment = .leading
        documentStack.spacing = documentStackSpacing
        documentStack.translatesAutoresizingMaskIntoConstraints = false
        flippedDocument.addSubview(documentStack)

        scrollView.documentView = flippedDocument
        root.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            // Document fills the scroll's width (so rows span the popover) and
            // is as tall as its content (vertical scroll past the cap).
            flippedDocument.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            // The outer-padded document stack inside the flipped document.
            documentStack.leadingAnchor.constraint(
                equalTo: flippedDocument.leadingAnchor, constant: outerPadding),
            documentStack.trailingAnchor.constraint(
                equalTo: flippedDocument.trailingAnchor, constant: -outerPadding),
            documentStack.topAnchor.constraint(
                equalTo: flippedDocument.topAnchor, constant: outerPadding),
            documentStack.bottomAnchor.constraint(
                equalTo: flippedDocument.bottomAnchor, constant: -outerPadding),
        ])

        view = root
        updatePreferredContentSize()
    }

    /// Recompute the popover's preferred content size from the document's
    /// fitting height (clamped to `maxHeight`) at the fixed width.
    func updatePreferredContentSize() {
        view.layoutSubtreeIfNeeded()
        let contentHeight = documentStack.fittingSize.height + 2 * outerPadding
        let height = min(contentHeight, maxHeight)
        preferredContentSize = NSSize(width: width, height: max(height, 1))
    }

    /// Replace the document stack's arranged subviews with `rows` and re-size.
    func populate(_ rows: [NSView]) {
        documentStack.arrangedSubviews.forEach {
            documentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for row in rows {
            row.translatesAutoresizingMaskIntoConstraints = false
            documentStack.addArrangedSubview(row)
            // Rows span the stack width.
            row.leadingAnchor.constraint(equalTo: documentStack.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: documentStack.trailingAnchor).isActive = true
        }
        updatePreferredContentSize()
    }
}

/// Flipped clip document so rows lay out top-down inside the scroll view.
final class PopoverFlippedClipView: NSView {
    override var isFlipped: Bool { true }
    nonisolated deinit {}
}
