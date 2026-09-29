import AppKit

/// What Claude asked the reader and what they chose, kept together like a
/// form that was filled in; live, the options are controls and **Submit**
/// answers (07-talk.md "AskUserQuestion").
@MainActor
final class QuestionRowView: NSView, PageRowView {
    typealias Model = Question

    weak var delegate: PageRowViewDelegate?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    static func height(for model: Question, width: CGFloat) -> CGFloat { 60 }

    func configure(with model: Question) {}
}
