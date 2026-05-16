import AppKit
import SwiftUI

/// Selectable text component bridged from NSTextField + custom cell so that
/// lineLimit and text selection both work.
///
/// - NSTextField natively supports `maximumNumberOfLines` +
///   `truncatesLastVisibleLine` (shows the ellipsis).
/// - On click, macOS installs a field editor that overrides the cell, which
///   defeats the line limit.
/// - `TruncatingCell` constrains the field editor's line count so it stays
///   within the truncation bounds.
struct SelectableText: NSViewRepresentable {
    let text: String
    var lineLimit: Int = 0
    var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)

    func makeNSView(context: Context) -> NSTextField {
        let cell = TruncatingCell(textCell: text)
        cell.isEditable = false
        cell.isSelectable = true
        cell.wraps = true
        cell.lineLimit = lineLimit
        cell.truncatesLastVisibleLine = true
        cell.lineBreakMode = .byCharWrapping
        cell.font = font

        let field = NSTextField(frame: .zero)
        field.cell = cell
        field.isEditable = false
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        field.maximumNumberOfLines = lineLimit
        field.font = font
        field.textColor = .labelColor
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        nsView.stringValue = text
        nsView.maximumNumberOfLines = lineLimit
        (nsView.cell as? TruncatingCell)?.lineLimit = lineLimit
        nsView.font = font
    }
}

/// Custom NSTextFieldCell that constrains the field editor to the cell's
/// own line limit.
private final class TruncatingCell: NSTextFieldCell {

    var lineLimit: Int = 0

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        guard let editor = super.fieldEditor(for: controlView) else { return nil }
        editor.textContainer?.maximumNumberOfLines = lineLimit
        editor.textContainer?.lineBreakMode = .byTruncatingTail
        return editor
    }

    override func select(
        withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int,
        length selLength: Int
    ) {
        if let textView = textObj as? NSTextView {
            textView.textContainer?.maximumNumberOfLines = lineLimit
            textView.textContainer?.lineBreakMode = .byTruncatingTail
        }
        super.select(
            withFrame: rect, in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }

    override func edit(
        withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?
    ) {
        if let textView = textObj as? NSTextView {
            textView.textContainer?.maximumNumberOfLines = lineLimit
            textView.textContainer?.lineBreakMode = .byTruncatingTail
        }
        super.edit(withFrame: rect, in: controlView, editor: textObj, delegate: delegate, event: event)
    }
}
