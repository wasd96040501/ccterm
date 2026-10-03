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
        var hinted: [(item: NSMenuItem, title: String, hint: String)] = []
        for (index, section) in menu.sections.enumerated() {
            if index > 0 { result.addItem(.separator()) }
            if let header = section.header {
                let item = NSMenuItem.sectionHeader(title: header)
                if let hint = section.headerHint { hinted.append((item, header, hint)) }
                result.addItem(item)
            }
            for item in section.items {
                result.addItem(makeItem(item, target: target, action: action))
            }
        }
        // The key hint at the header's trailing edge, where a key equivalent
        // ends (the design's `.mh` with its `kbd`): right-aligned at the width
        // the items already give the menu, so it never widens it.
        let width = result.size.width
        for (item, title, hint) in hinted {
            // What the header adds around its line in this menu — its indent
            // and the trailing margin: made the widest line at a known width.
            let probe: CGFloat = 2000
            item.attributedTitle = header(title, hint: hint, endingAt: probe)
            let chrome = result.size.width - probe
            item.attributedTitle = header(title, hint: hint, endingAt: width - chrome)
        }
        return result
    }

    private static let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)

    private static func header(_ title: String, hint: String, endingAt location: CGFloat) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: location)]
        let text = NSMutableAttributedString(
            string: title, attributes: [.font: headerFont, .foregroundColor: NSColor.tertiaryLabelColor])
        text.append(
            NSAttributedString(
                string: "\t\(hint)",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]))
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        return text
    }

    private static func makeItem(_ item: ComposerModel.Item, target: AnyObject, action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: item.title, action: action, keyEquivalent: "")
        menuItem.target = target
        menuItem.representedObject = Choice(item.change)
        menuItem.isEnabled = item.isEnabled
        menuItem.state = item.isChecked ? .on : .off
        menuItem.image = item.glyph.flatMap { ComposerGlyph.image($0, size: 16) }.map(rowSized)
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

    /// `image` in a row glyph's 16-pt box (the design's `.mi .g`), scaled down
    /// to fit if it is larger, centred — so every item's words start at the
    /// same column and no glyph stands taller than its row's.
    private static func rowSized(_ image: NSImage) -> NSImage {
        let box = NSSize(width: 16, height: 16)
        let scale = min(1, box.width / image.size.width, box.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let fitted = NSImage(size: box, flipped: false) { rect in
            image.draw(
                in: NSRect(
                    x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width,
                    height: size.height))
            return true
        }
        fitted.isTemplate = image.isTemplate
        return fitted
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
