import AppKit
import TranscriptKit

/// A window with a `TranscriptView` in it, driven entirely by `.view` rows —
/// the one row kind the package renders today. Run with `swift run
/// TranscriptKitDemo`.
///
/// What it is for: scrolling by hand and dragging the window across the content
/// width clamp. Everything a probe can't tell you.
@main
struct Demo {

    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "TranscriptKit — .view rows"

        let host = DemoHost()
        let root = NSView()
        window.contentView = root

        let transcript = TranscriptView()
        transcript.translatesAutoresizingMaskIntoConstraints = false
        transcript.dataSource = host
        transcript.delegate = host
        // Host policy: content stops widening at a readable measure and the
        // window keeps the rest as margin.
        transcript.maxContentWidth = 720

        root.addSubview(transcript)
        NSLayoutConstraint.activate([
            transcript.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            transcript.topAnchor.constraint(equalTo: root.topAnchor),
            transcript.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        transcript.contentInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        transcript.reloadData()

        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}

/// Data source and delegate for the demo: a fixed script of paragraphs, each one
/// a `.view` row.
@MainActor
private final class DemoHost: NSObject, TranscriptViewDataSource, TranscriptViewDelegate {

    private let messages: [DemoMessage] = DemoMessage.script

    func numberOfRows(in transcriptView: TranscriptView) -> Int {
        messages.count
    }

    func transcriptView(
        _ transcriptView: TranscriptView, contentForRow row: Int
    ) -> TranscriptRowContent {
        .view
    }

    /// Measured from the model at the width the transcript hands over — never by
    /// building a view. The bubble's own constraints have to land on the same
    /// number, or Auto Layout says so out loud.
    func transcriptView(
        _ transcriptView: TranscriptView, heightOfRow row: Int, width: CGFloat
    ) -> CGFloat {
        MessageBubbleView.height(for: messages[row], width: width)
    }

    func transcriptView(
        _ transcriptView: TranscriptView, viewForRow row: Int
    ) -> NSView {
        let bubble = transcriptView.makeView(withIdentifier: .bubble) { MessageBubbleView() }
        bubble.configure(with: messages[row])
        return bubble
    }
}

extension NSUserInterfaceItemIdentifier {
    fileprivate static let bubble = NSUserInterfaceItemIdentifier("demo.bubble")
}

private struct DemoMessage {
    enum Author { case user, assistant }

    let author: Author
    let text: String

    /// Enough rows to scroll through several screenfuls, with lengths varied so
    /// row heights differ and recycling has something to get wrong.
    static var script: [DemoMessage] {
        let bodies = [
            "Give me a one-paragraph summary of what changed in this branch.",
            "The transcript now serves every row through a cell view that keeps the "
                + "hosted view at the content width and centres it. The table frames the "
                + "cell; the cell's interior is Auto Layout. Nothing competes for a frame.",
            "Why not centre it by narrowing the table itself?",
            "Because the scroll view rewrites the document view's width back to the "
                + "clip's on every tile, and not through setFrameSize, so the clamp cannot "
                + "hold from inside the table. That was measured, not assumed.",
            "Short one.",
            "A longer answer, to make the row heights uneven: the content width is "
                + "resolved by a single function, which both the height query and the cell's "
                + "layout call. Measuring at one width and laying out at another is the "
                + "failure this design is shaped to make unrepresentable, so the two callers "
                + "share one implementation rather than agreeing by convention. Drag the "
                + "window narrower than 720 points and every row reflows; drag it wider and "
                + "the content stops growing while the margins take the difference.",
            "How do the views get recycled?",
            "Cells and the views inside them recycle as a pair, so a row coming back "
                + "into the viewport rebuilds no constraints — scroll to the bottom and back "
                + "and the same handful of bubbles has served every row.",
        ]
        return (0..<8).flatMap { block in
            bodies.enumerated().map { index, body in
                DemoMessage(
                    author: index.isMultiple(of: 2) ? .user : .assistant,
                    text: "\(block * bodies.count + index + 1). \(body)")
            }
        }
    }
}

/// The demo's hosted view: a rounded bubble with a wrapping label inside it.
///
/// Deliberately a constraint subtree rather than a self-drawn view — that is the
/// case the cell has to serve, and the case a frame-setting approach to centring
/// could not have served.
@MainActor
private final class MessageBubbleView: NSView {

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
