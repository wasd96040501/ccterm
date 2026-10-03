import AppKit

/// *Show 85 more* in link colour, under an expanded run's twelfth item: a
/// longer list is a log, and the reader asks for it (01-run.md "Expanded").
/// As tall as an item, so it ends the list with the same air below.
@MainActor
public final class ShowMoreRowView: NSView, PageRowView {
    public struct Model: Equatable {
        let runID: String
        let hidden: Int

        public init(runID: String, hidden: Int) {
            self.runID = runID
            self.hidden = hidden
        }
    }

    public weak var delegate: PageRowViewDelegate?

    /// An item's indent, then an item's words: two tiles and a gap's worth.
    private static let leading: CGFloat = 48

    private let label = NSTextField(labelWithString: "")
    private var runID: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13)
        label.textColor = .linkColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leading),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    public convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    public static func height(for model: Model, width: CGFloat) -> CGFloat { WorkRowMetrics.height }

    public func configure(with model: Model) {
        runID = model.runID
        label.stringValue = String(localized: "Show \(model.hidden) more", bundle: .module)
        setAccessibilityLabel(label.stringValue)
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    public override func mouseDown(with event: NSEvent) {
        if let runID { delegate?.pageRowView(self, didRequestAllItemsOf: runID) }
        super.mouseDown(with: event)
    }
}
