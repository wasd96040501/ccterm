import AppKit

/// One row of a form group: a title, the control it labels at the trailing
/// edge on the title's line, and an optional description under both that
/// stops 62 short of the row's end — the grouped `Form` row of System
/// Settings.
@MainActor
final class FormRowView: NSView {
    /// The line under the title; `nil` hides it.
    var detail: String? {
        didSet { updateDetail() }
    }

    /// Shows the description as an error.
    var isDetailError = false {
        didSet { updateDetail() }
    }

    private let titleLabel: NSTextField
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let accessory: NSView?
    private var detailConstraints: [NSLayoutConstraint] = []
    private var noDetailConstraints: [NSLayoutConstraint] = []

    init(title: String, accessory: NSView? = nil) {
        titleLabel = NSTextField(labelWithString: title)
        self.accessory = accessory
        super.init(frame: .zero)
        configureHierarchy()
        configureConstraints()
        updateDetail()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func configureHierarchy() {
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        for view in [titleLabel, detailLabel] + [accessory].compactMap({ $0 }) {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
    }

    private func configureConstraints() {
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var constraints = [
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10.5),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 37),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -62),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
        ]
        if let accessory {
            accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
            constraints += [
                accessory.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),
                accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                accessory.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            ]
        } else {
            constraints.append(titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10))
        }
        NSLayoutConstraint.activate(constraints)
        detailConstraints = [detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10.5)]
        noDetailConstraints = [titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10.5)]
    }

    private func updateDetail() {
        detailLabel.stringValue = detail ?? ""
        detailLabel.textColor = isDetailError ? .systemRed : .secondaryLabelColor
        detailLabel.isHidden = detail == nil
        NSLayoutConstraint.deactivate(detail == nil ? detailConstraints : noDetailConstraints)
        NSLayoutConstraint.activate(detail == nil ? noDetailConstraints : detailConstraints)
    }
}
