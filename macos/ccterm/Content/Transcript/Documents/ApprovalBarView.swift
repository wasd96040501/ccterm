import AppKit

/// Under the jump bar of a document whose call waits for the reader: *Claude
/// wants to run this command* · the reason · **Deny** / **Allow** — the same
/// buttons and keys as the card in the transcript; answering either answers
/// both (02-command.md "Live").
@MainActor
final class ApprovalBarView: NSView {
    weak var delegate: ApprovalBarViewDelegate?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// `call` is waiting (`ToolCallState.waiting`).
    func configure(with call: ToolCall) {}
}
