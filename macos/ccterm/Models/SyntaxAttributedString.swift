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
}
