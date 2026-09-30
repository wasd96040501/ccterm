import AppKit

/// How the documents draw a `LineSpan`: the transcript code card's palette for
/// source and shell (design/transcript/preview.css `.k` `.s` `.c` `.num` `.ty`
/// `.fn`), and the ANSI colours as the command output maps them. Nothing else
/// in the app has a syntax palette, so it lives with the views that use it.
extension LineSpan.Style {
    /// The colour the span is set in; `nil` keeps the line's own.
    var color: NSColor? {
        switch self {
        case .keyword: .syntax(light: 0x9B2393, dark: 0xFC5FA3)
        case .string: .syntax(light: 0xC41A16, dark: 0xFC6A5D)
        case .comment: .syntax(light: 0x5D6C79, dark: 0x6C7986)
        case .number: .syntax(light: 0x1C00CF, dark: 0xD0BF69)
        case .type: .syntax(light: 0x3900A0, dark: 0xD0A8FF)
        case .function: .syntax(light: 0x326D74, dark: 0x67B7A4)
        case .green, .boldGreen: .addedText
        case .red: .failureText
        case .bold: nil
        }
    }

    var weight: NSFont.Weight? {
        switch self {
        case .keyword: .semibold
        case .bold, .boldGreen: .bold
        default: nil
        }
    }
}

extension NSMutableAttributedString {
    /// Sets `spans` — offsets within one line that starts at `offset` here —
    /// in their colours, and in bold where they ask.
    func apply(_ spans: [LineSpan], at offset: Int, size: CGFloat) {
        for span in spans {
            let range = NSRange(location: offset + span.range.lowerBound, length: span.range.count)
            guard NSMaxRange(range) <= length else { continue }
            if let color = span.style.color { addAttribute(.foregroundColor, value: color, range: range) }
            if let weight = span.style.weight {
                addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: size, weight: weight), range: range)
            }
        }
    }
}

extension NSColor {
    /// A colour of the code card's palette, in both appearances.
    static func syntax(light: UInt32, dark: UInt32) -> NSColor {
        func color(_ hex: UInt32) -> NSColor {
            NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? color(dark) : color(light)
        }
    }

    /// A tint of `color` whose strength differs by appearance
    /// (preview.css `--add-bg`, `--del-bg`, `--add-hl`, `--del-hl`).
    static func wash(_ color: NSColor, light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return color.withAlphaComponent(isDark ? dark : light)
        }
    }
}
