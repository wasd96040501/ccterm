import AppKit

/// A form row's pop-up menu as a grouped `Form` draws its picker: the
/// chosen item's title, 12 apart from a 20-point round indicator with the
/// up-down chevrons. The menu is `NSPopUpButton`'s own — it opens with the
/// chosen item over the title.
@MainActor
public final class FormPopUpButton: NSPopUpButton {
    public init() {
        super.init(frame: .zero, pullsDown: false)
        cell = Cell(textCell: "", pullsDown: false)
        isBordered = false
        font = .systemFont(ofSize: 13)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Adds an item titled `title`; `detail` follows it in the menu only,
    /// in secondary ink — “Auth Token  Authorization: Bearer”.
    public func addItem(title: String, detail: String?, representedObject: Any?) {
        let item = Item(title: title, action: nil, keyEquivalent: "")
        item.plainTitle = title
        if let detail {
            let text = NSMutableAttributedString(string: title)
            text.append(
                NSAttributedString(string: "  " + detail, attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
            item.attributedTitle = text
        }
        item.representedObject = representedObject
        menu?.addItem(item)
    }

    /// A menu item that remembers its title without the menu-only detail —
    /// an attributed title replaces `title` too.
    private final class Item: NSMenuItem {
        var plainTitle = ""
    }

    /// Draws the title and the indicator; `NSPopUpButtonCell` does the rest.
    private final class Cell: NSPopUpButtonCell {
        static let indicator: CGFloat = 20
        static let gap: CGFloat = 12
        /// The indicator's inset from the trailing edge.
        static let trailing: CGFloat = 2

        override var cellSize: NSSize {
            NSSize(width: ceil(title().size().width) + Self.gap + Self.indicator + Self.trailing, height: 20)
        }

        override func titleRect(forBounds rect: NSRect) -> NSRect {
            let size = title().size()
            let right = rect.maxX - Self.trailing - Self.indicator - Self.gap
            return NSRect(
                x: right - ceil(size.width), y: rect.midY - size.height / 2, width: ceil(size.width),
                height: size.height)
        }

        override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
            title().draw(in: titleRect(forBounds: cellFrame))
            let circle = NSRect(
                x: cellFrame.maxX - Self.trailing - Self.indicator, y: cellFrame.midY - Self.indicator / 2,
                width: Self.indicator, height: Self.indicator)
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.12 : 0.06).setFill()
            NSBezierPath(ovalIn: circle).fill()
            let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
                .applying(.init(hierarchicalColor: .labelColor))
            guard
                let chevrons = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
                    .withSymbolConfiguration(configuration)
            else { return }
            let size = chevrons.size
            chevrons.draw(
                in: NSRect(
                    x: circle.midX - size.width / 2, y: circle.midY - size.height / 2, width: size.width,
                    height: size.height))
        }

        /// The chosen item's plain title — never its menu-only extras.
        private func title() -> NSAttributedString {
            NSAttributedString(
                string: (selectedItem as? Item)?.plainTitle ?? selectedItem?.title ?? "",
                attributes: [
                    .font: font ?? .systemFont(ofSize: 13),
                    .foregroundColor: isEnabled ? NSColor.labelColor : .tertiaryLabelColor,
                ])
        }
    }
}
