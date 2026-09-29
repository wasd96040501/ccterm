import AppKit

/// One row of the variable list: a checkbox, the name and the value in the
/// monospaced face, and a warning glyph when the row may not do what it
/// looks like. Columns: 30 for the checkbox, the name and the value sharing
/// the rest 1.6 : 1, 22 for the glyph, 5 to spare. The fields edit in
/// place; the value field swaps its masked display for `editingValue` while
/// it is edited.
@MainActor
final class EnvironmentVariableCellView: NSTableCellView {
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let nameField = Field()
    let valueField = Field()
    private let warning = NSImageView()
    private var row: EnvironmentRow?

    init() {
        super.init(frame: .zero)
        configureHierarchy()
        configureConstraints()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Shows `row`; a field being edited keeps its text.
    func configure(with row: EnvironmentRow) {
        self.row = row
        checkbox.state = row.isEnabled ? .on : .off
        if nameField.currentEditor() == nil { nameField.stringValue = row.name }
        if valueField.currentEditor() == nil { valueField.stringValue = row.displayValue }
        warning.isHidden = row.warning == nil
        warning.toolTip = row.warning
        updateColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    /// Label ink; tertiary for a row that's off; white on the selection.
    func updateColors() {
        let onSelection = backgroundStyle == .emphasized
        for field in [nameField, valueField] {
            field.textColor =
                field.currentEditor() != nil
                ? .labelColor
                : onSelection
                    ? .alternateSelectedControlTextColor : row?.isEnabled == false ? .tertiaryLabelColor : .labelColor
        }
        warning.contentTintColor = onSelection ? .alternateSelectedControlTextColor : .formWarning
    }

    private func configureHierarchy() {
        nameField.setPlaceholder(String(localized: "Name"))
        valueField.setPlaceholder(String(localized: "Value"))
        warning.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: String(localized: "Warning"))?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        for field in [nameField, valueField] {
            field.onEditingChange = { [weak self] in self?.editingDidChange() }
        }
        for view in [checkbox, nameField, valueField, warning] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
    }

    private func configureConstraints() {
        NSLayoutConstraint.activate([
            checkbox.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            // A field spans its column less 2 each side; its text sits 4
            // further in, 6 from the column's edge.
            nameField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30 + 2),
            nameField.trailingAnchor.constraint(equalTo: valueField.leadingAnchor, constant: -4),
            valueField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(22 + 5 + 2)),
            // (name + 4) = 1.6 × (value + 4)
            nameField.widthAnchor.constraint(equalTo: valueField.widthAnchor, multiplier: 1.6, constant: 2.4),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueField.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameField.heightAnchor.constraint(equalToConstant: 20),
            valueField.heightAnchor.constraint(equalToConstant: 20),
            warning.centerXAnchor.constraint(equalTo: trailingAnchor, constant: -(5 + 11)),
            warning.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// Editing draws the field as a text box over the selection, which the
    /// row view leaves out.
    private func editingDidChange() {
        updateColors()
        superview?.needsDisplay = true
    }

    /// A cell's text field: borderless at rest, a white box with the focus
    /// ring while edited; the text centred on the row and inset 4.
    final class Field: NSTextField {
        /// The text to edit, when it isn't what's shown — the value unmasked.
        var editingValue: (() -> String?)?
        var onEditingChange: (() -> Void)?

        init() {
            super.init(frame: .zero)
            cell = Cell(textCell: "")
            isEditable = true
            isSelectable = true
            isBordered = false
            drawsBackground = false
            backgroundColor = .textBackgroundColor
            usesSingleLineMode = true
            // At rest a long name ends in an ellipsis; while edited it scrolls.
            lineBreakMode = .byTruncatingTail
            font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            wantsLayer = true
            layer?.cornerRadius = 4
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

        func setPlaceholder(_ placeholder: String) {
            placeholderAttributedString = NSAttributedString(
                string: placeholder,
                attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.tertiaryLabelColor])
        }

        override func becomeFirstResponder() -> Bool {
            if let value = editingValue?() { stringValue = value }
            drawsBackground = true
            cell?.isScrollable = true
            let became = super.becomeFirstResponder()
            onEditingChange?()
            return became
        }

        override func textDidEndEditing(_ notification: Notification) {
            super.textDidEndEditing(notification)
            endEditingDisplay()
        }

        override func abortEditing() -> Bool {
            let aborted = super.abortEditing()
            endEditingDisplay()
            return aborted
        }

        private func endEditingDisplay() {
            drawsBackground = false
            cell?.isScrollable = false
            cell?.lineBreakMode = .byTruncatingTail
            onEditingChange?()
        }

        /// Centres the line in the field and insets it 4 from the sides,
        /// for drawing and editing alike.
        private final class Cell: NSTextFieldCell {
            override func drawingRect(forBounds rect: NSRect) -> NSRect {
                let base = super.drawingRect(forBounds: rect.insetBy(dx: 2, dy: 0))
                let height = cellSize(forBounds: rect).height
                return NSRect(
                    x: base.minX, y: rect.minY + max(0, (rect.height - height) / 2), width: base.width,
                    height: min(height, rect.height))
            }
        }
    }
}
