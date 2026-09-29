import AppKit

/// *Show 85 more* in link colour, under an expanded run's twelfth item: a
/// longer list is a log, and the reader asks for it (01-run.md "Expanded").
@MainActor
final class ShowMoreRowView: NSView, PageRowView {
    struct Model: Equatable {
        let runID: String
        let hidden: Int
    }

    weak var delegate: PageRowViewDelegate?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    static func height(for model: Model, width: CGFloat) -> CGFloat { 24 }

    func configure(with model: Model) {}
}
