import AppKit
import DisplayModels

/// How every view draws the work voice's distinctions
/// (design/transcript/preview.css `.line`, `.jump .jstat`): the line keeps
/// its own font and colour; a noun is in label colour, code monospaced one
/// point smaller in label colour, added lines green, removed lines and
/// failures red.
extension StyledText {
    /// A noun that opens something carries its id under this key, so a view
    /// can find what a click on it opens (`characterIndex` → attribute).
    public static let opensKey = NSAttributedString.Key("ccterm.StyledText.opens")

    public func attributedString(font: NSFont, color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in runs {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            switch run.style {
            case .plain: break
            case .noun(let opens):
                attributes[.foregroundColor] = NSColor.labelColor
                attributes[Self.opensKey] = opens
            case .code:
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
                attributes[.foregroundColor] = NSColor.labelColor
            case .added: attributes[.foregroundColor] = NSColor.addedText
            case .removed, .failure: attributes[.foregroundColor] = NSColor.failureText
            }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }
}
