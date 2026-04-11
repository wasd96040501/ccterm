import SwiftUI

enum SyntaxAttributedString {

    /// Build an AttributedString from syntax tokens in O(N).
    static func build(
        tokens: [SyntaxToken],
        colorScheme: ColorScheme,
        font: Font = .system(size: 12, design: .monospaced)
    ) -> AttributedString {
        var result = AttributedString()
        for token in tokens {
            var part = AttributedString(token.text)
            part.foregroundColor = SyntaxTheme.color(for: token.scope, scheme: colorScheme)
            part.font = font
            result.append(part)
        }
        return result
    }

    /// Build an NSAttributedString from syntax tokens for use with NSTextView.
    static func buildNS(
        tokens: [SyntaxToken],
        colorScheme: ColorScheme,
        font: NSFont
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for token in tokens {
            let color = NSColor(SyntaxTheme.color(for: token.scope, scheme: colorScheme))
            result.append(NSAttributedString(string: token.text, attributes: [
                .font: font,
                .foregroundColor: color,
            ]))
        }
        return result
    }
}
