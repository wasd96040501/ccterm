import AppKit

/// A form section: a semibold header 10 above its group, and optionally
/// buttons under the group at its trailing edge (“Add Provider…”).
@MainActor
final class FormSectionView: NSView {
    init(title: String, content: NSView, trailingButtons: [NSButton] = []) {
        super.init(frame: .zero)
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        let buttons = NSStackView(views: trailingButtons)
        buttons.spacing = 8
        for view in [header, content, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        var constraints = [
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
        ]
        if trailingButtons.isEmpty {
            buttons.isHidden = true
            constraints.append(content.bottomAnchor.constraint(equalTo: bottomAnchor))
        } else {
            constraints += [
                buttons.topAnchor.constraint(equalTo: content.bottomAnchor, constant: 10),
                buttons.trailingAnchor.constraint(equalTo: trailingAnchor),
                buttons.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}
