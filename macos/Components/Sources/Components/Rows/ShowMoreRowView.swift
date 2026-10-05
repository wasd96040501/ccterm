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

    private let button = NSButton(title: "", target: nil, action: nil)
    private var runID: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.lineBreakMode = .byTruncatingTail
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.target = self
        button.action = #selector(showAll)
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leading),
            button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    public convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    public static func height(for model: Model, width: CGFloat) -> CGFloat { WorkRowMetrics.height }

    public func configure(with model: Model) {
        runID = model.runID
        button.attributedTitle = NSAttributedString(
            string: String(localized: "Show \(model.hidden) more", bundle: .module),
            attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.linkColor])
    }

    @objc private func showAll() {
        if let runID { delegate?.pageRowView(self, didRequestAllItemsOf: runID) }
    }
}
