import SwiftUI
import AppKit

/// 可选择文本组件，使用 NSTextField + 自定义 cell 桥接，正确支持 lineLimit + 文本选择。
///
/// - NSTextField 原生支持 `maximumNumberOfLines` + `truncatesLastVisibleLine`（显示省略号）
/// - 默认 NSTextField 被点击时 macOS 会安装 field editor 覆盖 cell，导致 lineLimit 失效
/// - 自定义 `TruncatingCell` 限制 field editor 的行数，使其不会超出截断范围
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

// MARK: - TruncatingCell

/// 自定义 NSTextFieldCell，限制 field editor 不超出 cell 自身的行数限制。
private final class TruncatingCell: NSTextFieldCell {

    var lineLimit: Int = 0

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        guard let editor = super.fieldEditor(for: controlView) else { return nil }
        editor.textContainer?.maximumNumberOfLines = lineLimit
        editor.textContainer?.lineBreakMode = .byTruncatingTail
        return editor
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        if let textView = textObj as? NSTextView {
            textView.textContainer?.maximumNumberOfLines = lineLimit
            textView.textContainer?.lineBreakMode = .byTruncatingTail
        }
        super.select(withFrame: rect, in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        if let textView = textObj as? NSTextView {
            textView.textContainer?.maximumNumberOfLines = lineLimit
            textView.textContainer?.lineBreakMode = .byTruncatingTail
        }
        super.edit(withFrame: rect, in: controlView, editor: textObj, delegate: delegate, event: event)
    }
}
