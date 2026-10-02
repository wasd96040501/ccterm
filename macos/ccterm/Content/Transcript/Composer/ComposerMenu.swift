import AppKit

/// A `ComposerModel.Menu` as the `NSMenu` Effort and Mode open (design 08
/// *Effort*, *Permission mode*): a section header with its key hint, items with
/// the glyph before and the subtitle under, the current one checked, the
/// unavailable ones greyed with their reason as the subtitle, Bypass in red.
@MainActor
enum ComposerMenu {
    /// The change an item of a built menu stands for.
    final class Choice: NSObject {
        let change: SessionSettings.Change
        init(_ change: SessionSettings.Change) { self.change = change }
    }

    /// Builds the menu; every enabled item sends `action` to `target` with its
    /// `Choice` as `representedObject`.
    static func make(_ menu: ComposerModel.Menu, target: AnyObject, action: Selector) -> NSMenu {
        let result = NSMenu()
        result.autoenablesItems = false
        for (index, section) in menu.sections.enumerated() {
            if index > 0 { result.addItem(.separator()) }
            if let header = section.header {
                result.addItem(headerItem(header, hint: section.headerHint))
            }
            for item in section.items {
                result.addItem(makeItem(item, target: target, action: action))
            }
        }
        return result
    }

    private static func headerItem(_ title: String, hint: String?) -> NSMenuItem {
        let item = NSMenuItem.sectionHeader(title: title)
        if let hint {
            // The key hint at the trailing edge, as the design's header has it.
            let style = NSMutableParagraphStyle()
            style.tabStops = [NSTextTab(textAlignment: .right, location: 250)]
            let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            let text = NSMutableAttributedString(
                string: title, attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor])
            text.append(
                NSAttributedString(
                    string: "\t\(hint)",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor,
                    ]))
            text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
            item.attributedTitle = text
        }
        return item
    }

    private static func makeItem(_ item: ComposerModel.Item, target: AnyObject, action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: item.title, action: action, keyEquivalent: "")
        menuItem.target = target
        menuItem.representedObject = Choice(item.change)
        menuItem.isEnabled = item.isEnabled
        menuItem.state = item.isChecked ? .on : .off
        menuItem.image = item.glyph.flatMap { ComposerGlyph.image($0, size: 16) }
        if let subtitle = item.subtitle {
            if #available(macOS 14.4, *) {
                menuItem.subtitle = subtitle
            } else {
                menuItem.attributedTitle = twoLines(item.title, subtitle)
            }
        }
        if item.isDanger, item.isEnabled {
            menuItem.attributedTitle = NSAttributedString(
                string: item.title,
                attributes: [.foregroundColor: NSColor.failureText, .font: NSFont.menuFont(ofSize: 0)]
            )
            menuItem.image = menuItem.image.map { tinted($0, .failureText) }
            if #available(macOS 14.4, *), let subtitle = item.subtitle { menuItem.subtitle = subtitle }
        }
        return menuItem
    }

    /// The title with its subtitle under it, for a system that has no
    /// `NSMenuItem.subtitle`.
    private static func twoLines(_ title: String, _ subtitle: String) -> NSAttributedString {
        let text = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        text.append(
            NSAttributedString(
                string: "\n" + subtitle,
                attributes: [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        return text
    }

    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        let copy = image.copy() as? NSImage ?? image
        copy.isTemplate = false
        return NSImage(size: copy.size, flipped: false) { rect in
            copy.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
