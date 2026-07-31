import AppKit
import TranscriptKit

/// A window with a `TranscriptView` in it, driven entirely by `.view` rows —
/// the one row kind the package renders today. Run with `swift run
/// TranscriptKitDemo`.
///
/// What it is for: the things a probe can't tell you. Scroll by hand and drag the
/// window across the content width clamp; then use the panel to mutate rows above
/// the viewport and watch that the text under your eyes doesn't move, which is the
/// one property the tests can assert but not convince anyone of.
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
        host.transcript = transcript

        let panel = ControlPanelView()
        panel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(transcript)
        root.addSubview(panel)
        NSLayoutConstraint.activate([
            transcript.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            transcript.topAnchor.constraint(equalTo: root.topAnchor),
            // The full height, chrome included: the panel is something rows scroll
            // under, not something that takes their space away.
            transcript.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            panel.heightAnchor.constraint(equalToConstant: ControlPanelView.height),
        ])

        // The inset the panel earns: the last row comes to rest above the blur
        // rather than behind it. Written by the host, from a height the host knows
        // — nothing in the transcript watches for chrome.
        transcript.contentInsets = NSEdgeInsets(
            top: 12, left: 0, bottom: ControlPanelView.height + 12, right: 0)

        panel.onScrollToRow = { row, position in
            transcript.scrollToRow(at: row, scrollPosition: position)
        }
        panel.onPrepend = { host.prepend(5) }
        panel.onAppend = { host.append() }
        panel.onRemoveTop = { host.removeTop(3) }
        panel.onGrowFirst = { host.growFirstRow() }
        panel.onRemeasureFirst = { host.remeasureFirstRow() }
        panel.onBatch = { host.prependAndRemoveInOneBatch() }
        panel.onMaxContentWidth = { transcript.maxContentWidth = $0 }
        host.onRowCountChange = { panel.setStatus("\($0) rows") }

        // Lay the tree out before loading, so the table's first — and only —
        // measurement pass runs at the settled content width. Loading first
        // measures every row twice: once at the width the transcript has before
        // Auto Layout has run (zero), then again once it has a real one, and the
        // correcting pass is a full-table `noteHeightOfRows`, which AppKit
        // animates. The first screen then arrives and visibly settles.
        //
        // `NSTableView` behaves the same way for the same reason, so this is the
        // host's job rather than something the transcript could take over: mount,
        // lay out, then load.
        root.layoutSubtreeIfNeeded()
        transcript.reloadData()
        panel.setStatus("\(transcript.numberOfRows) rows")

        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}

/// Data source and delegate for the demo: a script of paragraphs, each one a
/// `.view` row, plus the mutations the control panel drives.
///
/// Every mutation is the same two lines a real host writes — change the model,
/// then announce the change — and each announcement is deliberately the
/// index-based one rather than `reloadData()`, since that is what scroll
/// anchoring applies to.
@MainActor
private final class DemoHost: NSObject, TranscriptViewDataSource, TranscriptViewDelegate {

    private var messages: [DemoMessage] = DemoMessage.script
    private var mutationCount = 0

    weak var transcript: TranscriptView?
    var onRowCountChange: ((Int) -> Void)?

    // MARK: - Mutations

    /// Above the viewport, wherever the viewport is: the case where holding the
    /// content still is the whole point.
    func prepend(_ count: Int) {
        let inserted = (0..<count).map { index in
            DemoMessage(author: .assistant, text: label("▲ prepended", index))
        }
        messages.insert(contentsOf: inserted, at: 0)
        transcript?.insertRows(at: IndexSet(0..<count))
        reportRowCount()
    }

    /// Below everything: the case where the answer depends on where the reader is
    /// — at the end it follows, anywhere else it doesn't move.
    func append() {
        messages.append(DemoMessage(author: .user, text: label("▼ appended", 0)))
        transcript?.insertRows(at: IndexSet(integer: messages.count - 1))
        reportRowCount()
    }

    func removeTop(_ count: Int) {
        let removed = min(count, messages.count)
        guard removed > 0 else { return }
        messages.removeFirst(removed)
        transcript?.removeRows(at: IndexSet(0..<removed))
        reportRowCount()
    }

    /// A row above the viewport changing height without changing identity — the
    /// mutation that has no index set to shift, only geometry to compensate for.
    func growFirstRow() {
        guard !messages.isEmpty else { return }
        let grown = String(repeating: "This row keeps growing. ", count: 6)
        messages[0] = DemoMessage(
            author: messages[0].author, text: "\(messages[0].text) \(grown)")
        transcript?.reloadRows(at: IndexSet(integer: 0))
    }

    /// The same height change announced without re-rendering the row: the other
    /// public path to it, and the one a hosted view uses when it grows itself.
    func remeasureFirstRow() {
        guard !messages.isEmpty else { return }
        let grown = String(repeating: "Re-measured, not re-rendered. ", count: 4)
        messages[0] = DemoMessage(
            author: messages[0].author, text: "\(messages[0].text) \(grown)")
        transcript?.noteHeightOfRows(withIndexesChanged: IndexSet(integer: 0))
    }

    /// Two mutations, one anchor: five rows in at the top and three out from just
    /// below them, so the renumbering has to compose across the group.
    func prependAndRemoveInOneBatch() {
        guard messages.count > 13 else { return }
        transcript?.beginUpdates()
        prepend(5)
        messages.removeSubrange(10..<13)
        transcript?.removeRows(at: IndexSet(10..<13))
        transcript?.endUpdates()
        reportRowCount()
    }

    private func label(_ prefix: String, _ index: Int) -> String {
        mutationCount += 1
        return "\(prefix) #\(mutationCount).\(index) — watch whether this pushed the text you "
            + "were reading off its line."
    }

    private func reportRowCount() {
        onRowCountChange?(messages.count)
    }

    // MARK: - Data source and delegate

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
