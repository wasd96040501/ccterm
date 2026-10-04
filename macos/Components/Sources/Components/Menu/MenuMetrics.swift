import AppKit

/// The design's numbers for a menu (`.lv-po`, `.mi`, `.mh`, `.msep`), as
/// measured on the sheet: x is from the popover's leading edge.
enum MenuMetrics {
    /// The list's padding inside the popover, and a row's inset within it
    /// (`.lv-po .mscroll` 10): rows 10 round, concentric with the popover's 20.
    static let inset: CGFloat = 10
    /// The filter field's inset from the popover's edges and the list's gap
    /// under it (`.mfilter` 7, `.mfilter + .mscroll` 3): its 26-pt capsule
    /// concentric with the popover's corners.
    static let filterInset: CGFloat = 7
    static let filterGap: CGFloat = 3
    /// Above the footer's rows, under its hairline (`.mfoot` 6).
    static let footerTop: CGFloat = 6
    /// A check's leading edge: the inset and the row's 6 (`.mi` padding).
    static let checkX: CGFloat = 16
    /// A 10-pt check in its 14-pt column.
    static let checkSize: CGFloat = 10
    /// The glyph column, after the check's 14 and a 4 gap; 20 wide, its glyph 16.
    static let glyphX: CGFloat = 34
    static let glyphSize: CGFloat = 16
    /// The words: after the glyph column's 20 and a 4 gap — or where the
    /// glyph column would start, when no item has a glyph (`.mi.nog`).
    static let wordsX: CGFloat = 58
    static let wordsXWithoutGlyphs: CGFloat = 34
    /// From the menu's trailing edge to a row's trailing words, glyph or switch:
    /// the inset and the row's 10.
    static let trailingInset: CGFloat = 20
    /// The grid's gap before the trailing column, there even when it is empty
    /// (`.mi` column-gap).
    static let columnGap: CGFloat = 4
    /// Before a key or a trailing glyph (`.mi .k` padding-left), and before a switch.
    static let keyGap: CGFloat = 16
    static let switchGap: CGFloat = 12
    /// A row's padding above and below its words.
    static let rowPadding: CGFloat = 3

    static let titleFont = NSFont.systemFont(ofSize: 13)
    static let subtitleFont = NSFont.systemFont(ofSize: 11)
    static let keyFont = NSFont.systemFont(ofSize: 12)
    static let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let hintFont = NSFont.systemFont(ofSize: 11)

    /// The sheet's 1.45 line: 13-pt words on an 18.85-pt line.
    static let titleLine: CGFloat = 13 * 1.45
    /// A subtitle's 14-pt lines and the 1 under them.
    static let subtitleLine: CGFloat = 14
    static let subtitleBottom: CGFloat = 1
    /// An 11-pt head on its 15.95-pt line, 4 above and 2 under (`.mh`).
    static let headerLine: CGFloat = 11 * 1.45
    static let headerTop: CGFloat = 4
    static let headerBottom: CGFloat = 2
    /// An account's head: 10 above, 4 under, its mark 14 at 16, words at 36 (`.mh.acct`).
    static let accountTop: CGFloat = 10
    static let accountBottom: CGFloat = 4
    static let accountMarkX: CGFloat = 16
    static let accountMarkSize: CGFloat = 14
    static let accountWordsX: CGFloat = 36
    /// The model list's height at most (`fixModelList`'s 360).
    static let maxListHeight: CGFloat = 360
    /// The hairline's 5 above and under, 20 in from either side (`.msep`).
    static let separatorHeight: CGFloat = 10.5

    /// Where `font`'s baseline sits on a line `height` tall, from its top:
    /// the half-leading above, then the ascent — the browser's placement.
    static func baseline(of font: NSFont, onLine height: CGFloat) -> CGFloat {
        (height - (font.ascender - font.descender)) / 2 + font.ascender
    }

    static func accountHeight(note: String?) -> CGFloat {
        accountTop + headerLine + (note == nil ? 0 : headerLine) + accountBottom
    }

    static func wordsX(glyphColumn: Bool) -> CGFloat { glyphColumn ? wordsX : wordsXWithoutGlyphs }

    /// The width the trailing column takes after the words, with the grid's
    /// gap before it and its own padding.
    static func trailingWidth(of trailing: MenuContent.Trailing) -> CGFloat {
        switch trailing {
        case .none: columnGap
        case .key(let words): columnGap + keyGap + ceil(width(of: words, font: keyFont))
        case .glyph: columnGap + keyGap + 14
        case .toggle: columnGap + switchGap + MenuSwitchMetrics.size.width
        }
    }

    /// Where an item's subtitle may run: from the words' column to its trailing accessory.
    static func subtitleWidth(of item: MenuContent.Item, menuWidth: CGFloat, glyphColumn: Bool) -> CGFloat {
        menuWidth - trailingInset - trailingWidth(of: item.trailing) - wordsX(glyphColumn: glyphColumn)
    }

    /// The subtitle in its 14-pt lines.
    static func subtitle(_ words: String, color: NSColor) -> NSAttributedString {
        let lines = NSMutableParagraphStyle()
        lines.minimumLineHeight = subtitleLine
        lines.maximumLineHeight = subtitleLine
        return NSAttributedString(
            string: words, attributes: [.font: subtitleFont, .foregroundColor: color, .paragraphStyle: lines])
    }

    static func subtitleLines(_ words: String, width: CGFloat) -> Int {
        let rect = subtitle(words, color: .labelColor).boundingRect(
            with: NSSize(width: max(width, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return max(1, Int((rect.height / subtitleLine).rounded()))
    }

    static func height(of row: MenuContent.Row, width: CGFloat, content: MenuContent) -> CGFloat {
        switch row {
        case .separator:
            return separatorHeight
        case .header(.title):
            return headerTop + headerLine + headerBottom
        case .header(.account(_, _, _, let note)):
            return accountHeight(note: note)
        case .item(let item):
            var height = rowPadding + titleLine + rowPadding
            if let subtitle = item.subtitle {
                let lines = subtitleLines(
                    subtitle, width: subtitleWidth(of: item, menuWidth: width, glyphColumn: content.hasGlyphColumn))
                height += CGFloat(lines) * subtitleLine + subtitleBottom
            }
            return height
        }
    }

    static func width(of words: String, font: NSFont) -> CGFloat {
        (words as NSString).size(withAttributes: [.font: font]).width
    }
}

/// The small switch at a setting's trailing edge (`.nsw`: 26 × 15).
enum MenuSwitchMetrics {
    static var size: NSSize {
        let toggle = NSSwitch()
        toggle.controlSize = .mini
        return toggle.intrinsicContentSize
    }
}

// MARK: - The list
