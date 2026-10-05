import AppKit

/// A form section: a semibold header 10 above its group, and optionally
/// buttons under the group at its trailing edge (“Add Provider…”).
@MainActor
public final class FormSectionView: NSView {
    /// Hides the buttons under the group; the section then ends with it.
    public var areTrailingButtonsHidden = false {
        didSet { updateButtons() }
    }

    private let buttons: NSStackView
    private var buttonConstraints: [NSLayoutConstraint] = []
    private var noButtonConstraints: [NSLayoutConstraint] = []

    public init(title: String, content: NSView, trailingButtons: [NSView] = []) {
        buttons = NSStackView(views: trailingButtons)
        super.init(frame: .zero)
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        buttons.spacing = 8
        for view in [header, content, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        buttonConstraints = [
            buttons.topAnchor.constraint(equalTo: content.bottomAnchor, constant: 10),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        noButtonConstraints = [content.bottomAnchor.constraint(equalTo: bottomAnchor)]
        areTrailingButtonsHidden = trailingButtons.isEmpty
        updateButtons()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func updateButtons() {
        buttons.isHidden = areTrailingButtonsHidden
        NSLayoutConstraint.deactivate(areTrailingButtonsHidden ? buttonConstraints : noButtonConstraints)
        NSLayoutConstraint.activate(areTrailingButtonsHidden ? noButtonConstraints : buttonConstraints)
    }
}
