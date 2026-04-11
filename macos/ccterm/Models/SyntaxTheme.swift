import SwiftUI

enum SyntaxTheme {

    /// Map hljs CSS class to SwiftUI Color (GitHub / GitHub Dark Dimmed).
    static func color(for scope: String?, scheme: ColorScheme) -> Color {
        guard let scope else { return plainColor(scheme) }

        // Normalize: "hljs-title.function_" → "hljs-title"
        let base = scope.contains(".") ? String(scope.prefix(while: { $0 != "." })) : scope

        switch base {
        case "hljs-keyword", "hljs-selector-tag", "hljs-deletion", "hljs-type":
            return scheme == .dark ? color(0xf47067) : color(0xd73a49)

        case "hljs-string", "hljs-regexp", "hljs-addition", "hljs-subst":
            return scheme == .dark ? color(0x96d0ff) : color(0x032f62)

        case "hljs-number":
            return scheme == .dark ? color(0x6cb6ff) : color(0x005cc5)

        case "hljs-comment", "hljs-meta":
            return scheme == .dark ? color(0x768390) : color(0x6a737d)

        case "hljs-built_in":
            return scheme == .dark ? color(0xf69d50) : color(0xe36209)

        case "hljs-title", "hljs-section":
            return scheme == .dark ? color(0xdcbdfb) : color(0x6f42c1)

        case "hljs-variable", "hljs-params", "hljs-template-variable":
            return scheme == .dark ? color(0xf69d50) : color(0xe36209)

        case "hljs-literal":
            return scheme == .dark ? color(0x6cb6ff) : color(0x005cc5)

        case "hljs-attr", "hljs-symbol", "hljs-bullet":
            return scheme == .dark ? color(0x6cb6ff) : color(0x005cc5)

        case "hljs-name", "hljs-tag":
            return scheme == .dark ? color(0x7ee787) : color(0x22863a)

        case "hljs-link":
            return scheme == .dark ? color(0x96d0ff) : color(0x032f62)

        default:
            return plainColor(scheme)
        }
    }

    static func plainColor(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? color(0xadbac7) : color(0x24292f)
    }

    private static func color(_ hex: Int) -> Color {
        Color(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
