import AppKit

/// The design's numbers for a menu (`.lv-menu`, `.mi`, `.mh`, `.msep`), as
/// measured on the sheet: x is from the menu's leading edge.
enum MenuMetrics {
    /// The menu's padding, and a row's inset within it (`.lv-menu` 5).
    static let inset: CGFloat = 5
    /// A check's leading edge: the inset and the row's 6 (`.mi` padding).
    static let checkX: CGFloat = 11
    /// A 10-pt check in its 14-pt column.
    static let checkSize: CGFloat = 10
    /// The glyph column, after the check's 14 and a 4 gap; 20 wide, its glyph 16.
    static let glyphX: CGFloat = 29
    static let glyphSize: CGFloat = 16
    /// The words: after the glyph column's 20 and a 4 gap — or where the
    /// glyph column would start, when no item has a glyph (`.mi.nog`).
    static let wordsX: CGFloat = 53
    static let wordsXWithoutGlyphs: CGFloat = 29
    /// From the menu's trailing edge to a row's trailing words, glyph or switch:
    /// the inset and the row's 10.
    static let trailingInset: CGFloat = 15
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
    /// An account's head: 8 above, 4 under, its mark 14 at 11, words at 31 (`.mh.acct`).
    static let accountTop: CGFloat = 8
    static let accountBottom: CGFloat = 4
    static let accountMarkX: CGFloat = 11
    static let accountMarkSize: CGFloat = 14
    static let accountWordsX: CGFloat = 31
    /// The hairline's 5 above and under, 15 in from either side (`.msep`).
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

    /// The menu width a row needs to set its words on one line.
    static func naturalWidth(of row: MenuContent.Row, content: MenuContent) -> CGFloat {
        switch row {
        case .separator:
            return 0
        case .header(.title(let title, let hint)):
            let hinted = hint.map { 12 + width(of: $0, font: hintFont) } ?? 0
            return inset + 24 + width(of: title, font: headerFont) + hinted + 10 + inset
        case .header(.account(_, let name, let detail, let note)):
            let line = accountWordsX + width(of: name, font: headerFont) + 6 + width(of: detail, font: hintFont)
            let under = accountWordsX + (note.map { width(of: $0, font: hintFont) } ?? 0)
            return max(line, under) + 10
        case .item(let item):
            let words = max(
                width(of: item.title, font: titleFont), item.subtitle.map { width(of: $0, font: subtitleFont) } ?? 0)
            return wordsX(glyphColumn: content.hasGlyphColumn) + words + trailingWidth(of: item.trailing)
                + trailingInset
        }
    }

    /// A panel's width (`.lv-menu.panel`).
    static let panelWidth: CGFloat = 300
    /// A menu's width, from its widest row (`.lv-menu`'s min- and max-width).
    static let menuWidths: ClosedRange<CGFloat> = 240...340

    /// The width `content` asks for, as a panel or an `NSMenu` draws it: a
    /// panel's fixed width, or a menu's widest row within its range.
    static func width(of content: MenuContent) -> CGFloat {
        if content.isPanel { return panelWidth }
        let widest = (content.rows + content.footer).map { naturalWidth(of: $0, content: content) }.max() ?? 0
        return min(max(ceil(widest), menuWidths.lowerBound), menuWidths.upperBound)
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
