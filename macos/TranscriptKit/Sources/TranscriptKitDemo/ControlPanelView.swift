import AppKit
import TranscriptKit

/// The demo's chrome: a blurred bar across the bottom of the window with the
/// controls that drive the transcript.
///
/// It is chrome on purpose. The host sets `contentInsets.bottom` to its height, so
/// rows scroll *underneath* the blur and come to rest above it — which is the
/// arrangement `contentInsets` exists for, and one that only reads as correct with
/// something translucent sitting there.
///
/// Reports intent through closures and never touches the transcript itself, so
/// what each control means stays at the one place that wires them up.
@MainActor
final class ControlPanelView: NSVisualEffectView {

    /// Fixed rather than derived from the stack, so the host can inset the
    /// transcript by it before anything has laid out.
    static let height: CGFloat = 200

    var onScrollToRow: ((Int, TranscriptView.ScrollPosition) -> Void)?
    var onPrepend: (() -> Void)?
    var onAppend: (() -> Void)?
    var onRemoveTop: (() -> Void)?
    var onBatch: (() -> Void)?
    var onMaxContentWidth: ((CGFloat) -> Void)?
    var onGrowFirst: (() -> Void)?
    var onRemeasureFirst: (() -> Void)?

    /// Start streaming into this row, or stop whatever is streaming — one
    /// control, because only one row streams at a time and the button's title
    /// says which state it is in.
    var onStream: ((Int) -> Void)?

    /// Load a transcript of this many rows, with the history either measured off
    /// the main actor first (`prepared`) or typeset inside the insert.
    var onColdLoad: ((Int, Bool) -> Void)?
    var onCancelColdLoad: (() -> Void)?

    private let rowField = NSTextField(string: "0")
    private let positions = NSSegmentedControl(
        labels: ["Top", "Center", "Bottom", "Nearest"], trackingMode: .selectOne,
        target: nil, action: nil)
    private let widthSlider = NSSlider(value: 720, minValue: 320, maxValue: 1200, target: nil, action: nil)
    private let widthLabel = NSTextField(labelWithString: "720 pt")
    private let statusLabel = NSTextField(labelWithString: "")

    /// Row 1 by default: the first assistant turn, which is the row kind worth
    /// watching grow. A user turn is one bubble carrying what someone typed and
    /// arrives whole, so nothing streams into one.
    private let streamField = NSTextField(string: "1")
    private lazy var streamButton = button("Stream", #selector(stream))

    /// Ten thousand, because that is the number the two buttons beside it stop
    /// being a matter of taste at. A few hundred rows load acceptably either way.
    private let coldLoadField = NSTextField(string: "10000")
    private let coldLoadLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active

        for field in [rowField, streamField, coldLoadField] {
            field.formatter = {
                let formatter = NumberFormatter()
                formatter.allowsFloats = false
                return formatter
            }()
        }
        positions.selectedSegment = 0
        widthSlider.target = self
        widthSlider.action = #selector(widthChanged)
        for label in [statusLabel, coldLoadLabel] {
            label.textColor = .secondaryLabelColor
            // Monospaced digits, or the timings jitter sideways as they update
            // once a chunk — which reads as the panel being the thing that is
            // struggling.
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        }

        let rows = NSStackView(views: [
            scrollRow(), mutationRow(), streamRow(), coldLoadRow(), widthRow(),
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 10
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)

        // The controls run off the right edge and are cut off, rather than
        // setting a floor under the window's width. `rows` is pinned on the
        // leading side only — no trailing constraint and no width — so its
        // natural width, which the slider's own 200pt makes several hundred
        // points, constrains nothing above it. The transcript is what a narrow
        // window is for looking at.
        clipsToBounds = true

        // A separator rather than a border: the panel's top edge is where content
        // disappears under it, and that edge wants to be legible.
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            rows.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            widthSlider.widthAnchor.constraint(equalToConstant: 200),
            rowField.widthAnchor.constraint(equalToConstant: 56),
            streamField.widthAnchor.constraint(equalToConstant: 56),
            coldLoadField.widthAnchor.constraint(equalToConstant: 72),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("code-only")
    }

    /// The row count, shown so a mutation's effect on the data is visible next to
    /// its effect on the scroll offset.
    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    /// Driven by the host rather than toggled here, because a stream also ends by
    /// running out of text — and a title kept locally would then say **Stop**
    /// over a row that had stopped.
    func setStreaming(_ streaming: Bool) {
        streamButton.title = streaming ? "Stop" : "Stream"
    }

    /// The cold load's running timings. Separate from `setStatus` because the two
    /// update on different clocks — the row count after every mutation, this
    /// after every chunk — and one label showing both would flicker between them.
    func setColdLoadStatus(_ text: String) {
        coldLoadLabel.stringValue = text
    }

    // MARK: - Rows

    private func scrollRow() -> NSStackView {
        let go = button("Scroll to row", #selector(scrollToRow))
        return row([NSTextField(labelWithString: "Row"), rowField, positions, go])
    }

    private func mutationRow() -> NSStackView {
        row([
            button("Prepend 5", #selector(prepend)),
            button("Append 1", #selector(append)),
            button("Remove top 3", #selector(removeTop)),
            button("Grow row 0", #selector(growFirst)),
            button("Re-measure row 0", #selector(remeasureFirst)),
            button("Batch", #selector(batch)),
        ])
    }

    /// The one control that runs on a clock. Everything else on this panel is a
    /// single mutation you watch land; this one keeps announcing the same row
    /// sixty times a second, which is the case the transcript's caching and its
    /// selection handling both exist for.
    private func streamRow() -> NSStackView {
        row([
            NSTextField(labelWithString: "Stream into row"), streamField, streamButton,
            NSTextField(
                labelWithString: "— select some text in it first, and scroll while it runs"),
        ])
    }

    /// The two cold loads, side by side on purpose.
    ///
    /// Neither button proves anything alone. **Prepared** looks unremarkable
    /// until you have watched **sync** load the same transcript and found the
    /// window unable to redraw, scroll or take a selection while it does — and
    /// the number the timing label prints beside them is the same number in both
    /// runs, so the comparison is not a matter of impression.
    private func coldLoadRow() -> NSStackView {
        let stack = row([
            NSTextField(labelWithString: "Cold load"), coldLoadField,
            button("Prepared", #selector(coldLoadPrepared)),
            button("Sync", #selector(coldLoadSync)),
            button("Cancel", #selector(cancelColdLoad)),
            coldLoadLabel,
        ])
        stack.setCustomSpacing(16, after: coldLoadField)
        return stack
    }

    private func widthRow() -> NSStackView {
        let stack = row([
            NSTextField(labelWithString: "Max content width"), widthSlider, widthLabel, statusLabel,
        ])
        stack.setCustomSpacing(24, after: widthLabel)
        return stack
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        return button
    }

    // MARK: - Actions

    @objc private func scrollToRow() {
        let position: TranscriptView.ScrollPosition =
            switch positions.selectedSegment {
            case 0: .top
            case 1: .center
            case 2: .bottom
            default: .nearestEdge
            }
        onScrollToRow?(rowField.integerValue, position)
    }

    @objc private func prepend() { onPrepend?() }
    @objc private func append() { onAppend?() }
    @objc private func removeTop() { onRemoveTop?() }
    @objc private func batch() { onBatch?() }

    @objc private func growFirst() { onGrowFirst?() }
    @objc private func remeasureFirst() { onRemeasureFirst?() }
    @objc private func stream() { onStream?(streamField.integerValue) }

    @objc private func coldLoadPrepared() { onColdLoad?(coldLoadField.integerValue, true) }
    @objc private func coldLoadSync() { onColdLoad?(coldLoadField.integerValue, false) }
    @objc private func cancelColdLoad() { onCancelColdLoad?() }

    @objc private func widthChanged() {
        let width = widthSlider.doubleValue.rounded()
        widthLabel.stringValue = "\(Int(width)) pt"
        onMaxContentWidth?(width)
    }
}
