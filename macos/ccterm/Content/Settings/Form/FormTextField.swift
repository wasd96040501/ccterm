import AppKit

/// A form row's text field: borderless, right-aligned on the title's line,
/// as a grouped `Form`'s `TextField` is. Paths, commands and model names
/// take the monospaced face.
@MainActor
final class FormTextField: NSTextField {
    /// `width`: the field's fixed width — 260 for most rows.
    init(placeholder: String, width: CGFloat = 260, monospaced: Bool = false) {
        super.init(frame: .zero)
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        alignment = .right
        usesSingleLineMode = true
        lineBreakMode = .byTruncatingTail
        cell?.isScrollable = true
        font = monospaced ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 13)
        placeholderString = placeholder
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}
