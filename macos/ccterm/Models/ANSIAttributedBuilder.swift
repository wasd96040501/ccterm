import AppKit

/// SGR (Select Graphic Rendition) → `NSAttributedString` for shell output.
///
/// Port of `web/src/utils/ansiParser.ts` — keeps the same 16-colour /
/// 256-colour cube / truecolor palette + bold/dim/italic/underline
/// handling so terminal output rendered through this builder matches
/// what the React side shows. We parse SGR escape sequences only;
/// non-SGR `CSI…` sequences (cursor moves, screen ops) are stripped to
/// match the regex in `ansiParser.ts`.
///
/// Colours are emitted as plain sRGB NSColors. They do **not** track
/// light/dark appearance — terminal palettes are picked to read against
/// a uniform background tone, and ours matches that tier
/// (`diffContainerBackground`). Bright variants pop on dark surface,
/// the dim/dark standards stay legible on light surface.
enum ANSIAttributedBuilder {

    /// Build an attributed string out of `text` honoring embedded SGR
    /// sequences. Glyph runs without any SGR attributes pick up
    /// `(baseFont, baseColor)`; attributed runs override foreground /
    /// background / weight / italic / underline / dim only where the
    /// sequence sets them.
    static func attributed(
        from text: String, baseFont: NSFont, baseColor: NSColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var current = Style()
        var search = text.startIndex

        while let escIdx = text[search...].firstIndex(of: "\u{1B}") {
            // Emit pending plain run before the escape.
            if escIdx > search {
                appendRun(
                    String(text[search..<escIdx]),
                    style: current,
                    base: (baseFont, baseColor),
                    into: result)
            }
            // Parse the CSI sequence starting at `esc` if it's well
            // formed. Anything malformed: drop the ESC byte and resume.
            guard let parsed = parseCSI(in: text, from: escIdx) else {
                search = text.index(after: escIdx)
                continue
            }
            if parsed.isSGR {
                current = applySGR(parsed.params, to: current)
            }
            search = parsed.end
        }

        if search < text.endIndex {
            appendRun(
                String(text[search...]),
                style: current,
                base: (baseFont, baseColor),
                into: result)
        }
        return result
    }

    // MARK: - Style state

    private struct Style {
        var bold: Bool = false
        var dim: Bool = false
        var italic: Bool = false
        var underline: Bool = false
        var fg: NSColor?
        var bg: NSColor?
    }

    // MARK: - Escape parsing

    private struct ParsedEscape {
        let params: String
        let isSGR: Bool
        let end: String.Index
    }

    /// Match `ESC[<digits/semicolons>m` (SGR) or `ESC[<anything>X`
    /// where `X` is any letter (other CSI ops). Returns `nil` for any
    /// other byte that follows `ESC` so the caller can resume.
    private static func parseCSI(
        in text: String, from start: String.Index
    ) -> ParsedEscape? {
        let after = text.index(after: start)
        guard after < text.endIndex, text[after] == "[" else { return nil }
        var i = text.index(after: after)
        var params = ""
        while i < text.endIndex {
            let c = text[i]
            if c == "m" {
                return ParsedEscape(
                    params: params, isSGR: true,
                    end: text.index(after: i))
            }
            if c.isLetter {
                // Non-SGR CSI — consume but report `isSGR = false` so
                // the run boundary still drops the byte stream.
                return ParsedEscape(
                    params: params, isSGR: false,
                    end: text.index(after: i))
            }
            params.append(c)
            i = text.index(after: i)
        }
        return nil
    }

    // MARK: - SGR application

    private static func applySGR(_ params: String, to style: Style) -> Style {
        let codes: [Int] = {
            if params.isEmpty { return [0] }
            return params.split(separator: ";").compactMap { Int($0) }
        }()
        var s = style
        var i = 0
        while i < codes.count {
            let c = codes[i]
            switch c {
            case 0:
                s = Style()
            case 1: s.bold = true
            case 2: s.dim = true
            case 3: s.italic = true
            case 4: s.underline = true
            case 22: s.bold = false; s.dim = false
            case 23: s.italic = false
            case 24: s.underline = false
            case 30...37: s.fg = standardColor(c - 30)
            case 39: s.fg = nil
            case 40...47: s.bg = standardColor(c - 40)
            case 49: s.bg = nil
            case 90...97: s.fg = brightColor(c - 90)
            case 100...107: s.bg = brightColor(c - 100)
            case 38, 48:
                let isFg = c == 38
                if i + 1 < codes.count, codes[i + 1] == 5, i + 2 < codes.count {
                    let idx = codes[i + 2]
                    if let color = palette256(idx) {
                        if isFg { s.fg = color } else { s.bg = color }
                    }
                    i += 2
                } else if i + 1 < codes.count, codes[i + 1] == 2,
                          i + 4 < codes.count
                {
                    let r = max(0, min(255, codes[i + 2]))
                    let g = max(0, min(255, codes[i + 3]))
                    let b = max(0, min(255, codes[i + 4]))
                    let color = NSColor(srgbRed: CGFloat(r) / 255,
                                        green: CGFloat(g) / 255,
                                        blue: CGFloat(b) / 255,
                                        alpha: 1)
                    if isFg { s.fg = color } else { s.bg = color }
                    i += 4
                }
            default:
                break
            }
            i += 1
        }
        return s
    }

    // MARK: - Palette

    /// Standard 8 colours (ANSI 30–37). Matches the hex values in
    /// `web/src/utils/ansiParser.ts` so terminal output reads identical
    /// to the React side.
    private static let standardHex: [UInt32] = [
        0x000000, 0xc23621, 0x25bc24, 0xadad27,
        0x492ee1, 0xd338d3, 0x33bbc8, 0xcbcccd,
    ]
    /// Bright 8 colours (ANSI 90–97).
    private static let brightHex: [UInt32] = [
        0x666666, 0xff6456, 0x4ae94a, 0xffff52,
        0x7d7dff, 0xff79ff, 0x60fdff, 0xffffff,
    ]

    private static func standardColor(_ idx: Int) -> NSColor {
        color(hex: standardHex[idx])
    }
    private static func brightColor(_ idx: Int) -> NSColor {
        color(hex: brightHex[idx])
    }

    private static func palette256(_ idx: Int) -> NSColor? {
        guard idx >= 0, idx < 256 else { return nil }
        if idx < 8 { return standardColor(idx) }
        if idx < 16 { return brightColor(idx - 8) }
        if idx < 232 {
            // 6×6×6 RGB cube
            let n = idx - 16
            let levels: [Int] = [0, 95, 135, 175, 215, 255]
            let r = levels[(n / 36) % 6]
            let g = levels[(n / 6) % 6]
            let b = levels[n % 6]
            return NSColor(srgbRed: CGFloat(r) / 255,
                           green: CGFloat(g) / 255,
                           blue: CGFloat(b) / 255,
                           alpha: 1)
        }
        // 24 greyscale ramp (8, 18, 28, …, 238)
        let v = 8 + (idx - 232) * 10
        return NSColor(srgbRed: CGFloat(v) / 255,
                       green: CGFloat(v) / 255,
                       blue: CGFloat(v) / 255,
                       alpha: 1)
    }

    private static func color(hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }

    // MARK: - Run emission

    private static func appendRun(
        _ text: String,
        style: Style,
        base: (font: NSFont, color: NSColor),
        into out: NSMutableAttributedString
    ) {
        guard !text.isEmpty else { return }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font(for: style, base: base.font),
            .foregroundColor: style.fg ?? base.color,
        ]
        if let bg = style.bg { attrs[.backgroundColor] = bg }
        if style.underline {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        // SGR `dim` halves perceived luminance — implement with
        // `.foregroundColor` alpha (0.5) baked over the resolved
        // colour so the run still composites correctly over the
        // section background.
        if style.dim, let fg = attrs[.foregroundColor] as? NSColor {
            attrs[.foregroundColor] = fg.withAlphaComponent(0.5)
        }
        out.append(NSAttributedString(string: text, attributes: attrs))
    }

    private static func font(for style: Style, base: NSFont) -> NSFont {
        var traits: NSFontDescriptor.SymbolicTraits = []
        if style.bold { traits.insert(.bold) }
        if style.italic { traits.insert(.italic) }
        if traits.isEmpty { return base }
        let desc = base.fontDescriptor.withSymbolicTraits(
            base.fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: desc, size: base.pointSize) ?? base
    }
}
