import AppKit
import TranscriptKit

/// The demo's hosted view: a rounded bubble with a wrapping label inside it.
///
/// Deliberately a constraint subtree rather than a self-drawn view — that is the
/// case the cell has to serve, and the case a frame-setting approach to centring
/// could not have served.
@MainActor
final class MessageBubbleView: NSView {

    private static let font = NSFont.systemFont(ofSize: 13)
    private static let padding: CGFloat = 12
    private static let verticalGap: CGFloat = 6

    private let label = NSTextField(wrappingLabelWithString: "")
    private let bubble = NSStackView()
    private var author: DemoMessage.Author = .assistant

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Only so `updateLayer` runs on an appearance change; the rounded fill
        // belongs to the bubble, not to the full-row view around it.
        wantsLayer = true

        label.font = Self.font
        label.isSelectable = false

        bubble.orientation = .vertical
        bubble.alignment = .leading
        bubble.edgeInsets = NSEdgeInsets(
            top: Self.padding, left: Self.padding, bottom: Self.padding, right: Self.padding)
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 10
        bubble.addArrangedSubview(label)
        bubble.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bubble)

        NSLayoutConstraint.activate([
            bubble.leadingAnchor.constraint(equalTo: leadingAnchor),
            bubble.trailingAnchor.constraint(equalTo: trailingAnchor),
            bubble.topAnchor.constraint(equalTo: topAnchor),
            // The gap between rows is space under the bubble, not bubble that
            // happens to be empty.
            bubble.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalGap),
            // A vertical stack sizes its arranged views to their intrinsic
            // width; the label has to be told to fill instead.
            label.widthAnchor.constraint(equalTo: bubble.widthAnchor, constant: -Self.padding * 2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("code-only")
    }

    func configure(with message: DemoMessage) {
        author = message.author
        label.stringValue = message.text
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // CGColors don't follow appearance changes on their own.
        let colour: NSColor =
            author == .user
            ? .controlAccentColor.withAlphaComponent(0.16)
            : .quaternaryLabelColor.withAlphaComponent(0.28)
        bubble.layer?.backgroundColor = colour.cgColor
    }

    /// The label the measurement runs through: the same class, font and
    /// wrapping as the one on screen.
    ///
    /// Measuring the raw string with `boundingRect` instead gets a different
    /// answer — the text field insets its text a couple of points inside its
    /// frame, so it wraps sooner than the bare string does, and every row comes
    /// out a line short.
    private static let measuringLabel: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = font
        return label
    }()

    /// The row height for `message` at `width`: the wrapped text, the bubble's
    /// padding, and the gap that separates one row from the next.
    static func height(for message: DemoMessage, width: CGFloat) -> CGFloat {
        measuringLabel.stringValue = message.text
        measuringLabel.preferredMaxLayoutWidth = max(1, width - padding * 2)
        return ceil(measuringLabel.fittingSize.height) + padding * 2 + verticalGap
    }
}
