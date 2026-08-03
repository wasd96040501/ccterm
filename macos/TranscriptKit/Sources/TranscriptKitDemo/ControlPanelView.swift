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
    static let height: CGFloat = 128

    var onScrollToRow: ((Int, TranscriptView.ScrollPosition) -> Void)?
    var onPrepend: (() -> Void)?
    var onAppend: (() -> Void)?
    var onRemoveTop: (() -> Void)?
    var onBatch: (() -> Void)?
    var onMaxContentWidth: ((CGFloat) -> Void)?
    var onGrowFirst: (() -> Void)?
    var onRemeasureFirst: (() -> Void)?

    private let rowField = NSTextField(string: "0")
    private let positions = NSSegmentedControl(
        labels: ["Top", "Center", "Bottom", "Nearest"], trackingMode: .selectOne,
        target: nil, action: nil)
    private let widthSlider = NSSlider(value: 720, minValue: 320, maxValue: 1200, target: nil, action: nil)
    private let widthLabel = NSTextField(labelWithString: "720 pt")
    private let statusLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active

        rowField.formatter = {
            let formatter = NumberFormatter()
            formatter.allowsFloats = false
            return formatter
        }()
        positions.selectedSegment = 0
        widthSlider.target = self
        widthSlider.action = #selector(widthChanged)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)

        let rows = NSStackView(views: [scrollRow(), mutationRow(), widthRow()])
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

    @objc private func widthChanged() {
        let width = widthSlider.doubleValue.rounded()
        widthLabel.stringValue = "\(Int(width)) pt"
        onMaxContentWidth?(width)
    }
}
