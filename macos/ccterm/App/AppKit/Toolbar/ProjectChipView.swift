import AppKit

/// Data type for the project-chip toolbar item. Two independent
/// display slots — a bold directory name over a secondary branch name —
/// each nil-safe (a nil field hides its label instead of showing an
/// empty row). Value-typed and `Equatable` so the coordinator can bail
/// out of a redundant `configure(with:)` call when the derived model
/// hasn't changed.
struct ProjectChipViewModel: Equatable {
    let directoryName: String?
    let branchName: String?
}

/// Leading toolbar chip: bold directory name over a secondary git branch
/// name. Sits inside an `NSToolbarItem.view` — the `intrinsicContentSize`
/// drives the toolbar's slot measurement, so no explicit width constraint
/// is needed.
///
/// Data comes in via `configure(with:)`. The view holds no domain
/// truth — it's a pure display: the coordinator derives the model from
/// the current selection + session and hands the result down.
@MainActor
final class ProjectChipView: NSView {
    private let stack = NSStackView()
    private let dirLabel = NSTextField(labelWithString: "")
    private let branchLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureHierarchy()
        configureConstraints()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func configureHierarchy() {
        translatesAutoresizingMaskIntoConstraints = false

        dirLabel.translatesAutoresizingMaskIntoConstraints = false
        dirLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        dirLabel.textColor = .labelColor
        dirLabel.lineBreakMode = .byTruncatingMiddle
        dirLabel.maximumNumberOfLines = 1
        dirLabel.cell?.wraps = false
        dirLabel.cell?.isScrollable = false

        branchLabel.translatesAutoresizingMaskIntoConstraints = false
        branchLabel.font = NSFont.systemFont(ofSize: 11)
        branchLabel.textColor = .secondaryLabelColor
        branchLabel.lineBreakMode = .byTruncatingMiddle
        branchLabel.maximumNumberOfLines = 1
        branchLabel.cell?.wraps = false
        branchLabel.cell?.isScrollable = false

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.distribution = .fill
        stack.addArrangedSubview(dirLabel)
        stack.addArrangedSubview(branchLabel)

        addSubview(stack)
    }

    private func configureConstraints() {
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// Idempotent binding. Each field independently shows/hides based on
    /// whether the view model provides a value. `invalidateIntrinsicContentSize`
    /// forces the toolbar to re-measure the slot when directory or branch
    /// text changes.
    func configure(with vm: ProjectChipViewModel) {
        dirLabel.stringValue = vm.directoryName ?? ""
        dirLabel.isHidden = (vm.directoryName == nil)
        branchLabel.stringValue = vm.branchName ?? ""
        branchLabel.isHidden = (vm.branchName == nil)
        invalidateIntrinsicContentSize()
    }

    /// Chip is measured off the stack's fitting size, capped at 220pt
    /// wide so an overlong path can't push the search field off the
    /// toolbar. Height matches the tallest visible label plus vertical
    /// breathing room.
    override var intrinsicContentSize: NSSize {
        let fitting = stack.fittingSize
        let width = min(220, fitting.width + 24)  // 12pt leading + 12pt trailing
        let height = max(28, fitting.height + 4)
        return NSSize(width: width, height: height)
    }

    nonisolated deinit {}
}
