import SwiftUI

/// hljs CSS class → SwiftUI Color, mapped to Xcode's "Default (Light/Dark)"
/// theme. Hex values are read from
/// `~/Library/Developer/Xcode/UserData/FontAndColorThemes/Default (*).xccolortheme`
/// (`DVTSourceTextSyntaxColors` dict, alpha dropped except for `plain`
/// which Xcode renders at 0.85 — folded into a flat hex here so the
/// existing `color(_:)` helper stays alpha-free).
///
/// Note on `hljs-title`: hljs emits *multi-class* scopes for declarations,
/// e.g. `"hljs-title class_"` for a struct/class name and
/// `"hljs-title function_"` for a function name (space-separated, not
/// dot-separated). Furthermore, when a class/struct lists a superclass or
/// protocol conformance, hljs tags those *references* with a `inherited__`
/// modifier on the same `hljs-title class_` base — so the modifier set
/// `{class_, inherited__}` actually means "this is a type reference," not
/// "this is a new declaration." We split on space and route accordingly:
///
///   - `hljs-title class_/struct_/enum_` *without* `inherited__` →
///     `identifier.type` teal (the name being defined here). Light is
///     a touch deeper than the raw plist value to stay legible against
///     the card background; dark uses the plist value verbatim.
///   - `hljs-title ... inherited__` (superclass / protocol conformance) →
///     `identifier.type.system` purple — same as `hljs-type` references
///   - `hljs-title function_` or bare `hljs-title` (CSS selectors,
///     markdown headings) → `identifier.function` teal
///
/// `hljs-type` covers all other *type references* (`Bool`, `String`,
/// `MarkdownDocument`, etc.) and goes to the same system-type purple as
/// `inherited__`. hljs can't distinguish user-defined references from
/// stdlib references, but Xcode's no-index fallback for any unresolved
/// type reference is the system-type tint, so we match that. The
/// declaration-blue / reference-purple split reproduces Xcode's "I wrote
/// this here / this points elsewhere" visual signal.
enum SyntaxTheme {

    static func color(for scope: String?, scheme: ColorScheme) -> Color {
        guard let scope, !scope.isEmpty else { return plainColor(scheme) }

        // Split "hljs-title class_ inherited__" → base="hljs-title",
        // modifier="class_ inherited__". Some highlighters also emit a
        // "."-suffix variant ("hljs-title.function_"); normalise that
        // into the same shape.
        let space = scope.split(separator: " ", maxSplits: 1).map(String.init)
        let firstPart = space[0]
        let base: String
        let modifier: String?
        if let dot = firstPart.firstIndex(of: ".") {
            base = String(firstPart[..<dot])
            modifier = String(firstPart[firstPart.index(after: dot)...])
        } else {
            base = firstPart
            modifier = space.count > 1 ? space[1] : nil
        }

        switch base {
        case "hljs-keyword", "hljs-selector-tag", "hljs-deletion":
            // xcode.syntax.keyword
            return scheme == .dark ? color(0xfc5fa3) : color(0x9b2393)

        case "hljs-type", "hljs-built_in":
            // xcode.syntax.identifier.type.system
            return scheme == .dark ? color(0xd0a8ff) : color(0x3900a0)

        case "hljs-string", "hljs-regexp", "hljs-addition", "hljs-subst":
            // xcode.syntax.string
            return scheme == .dark ? color(0xfc6a5d) : color(0xc41a16)

        case "hljs-number", "hljs-literal":
            // xcode.syntax.number
            return scheme == .dark ? color(0xd0bf69) : color(0x1c00cf)

        case "hljs-comment", "hljs-meta":
            // xcode.syntax.comment
            return scheme == .dark ? color(0x6c7986) : color(0x5d6b79)

        case "hljs-title", "hljs-section":
            if let modifier,
                modifier.hasPrefix("class_")
                    || modifier.hasPrefix("struct_")
                    || modifier.hasPrefix("enum_")
            {
                // `inherited__` — superclass / protocol conformance
                // *reference*. Same purple as `hljs-type`, not the
                // declaration tint.
                if modifier.contains("inherited__") {
                    return scheme == .dark ? color(0xd0a8ff) : color(0x3900a0)
                }
                // identifier.type — Xcode's user-declared-type tint.
                // Light is *recalibrated* for our context, not just
                // contrast-corrected: Xcode's plist value `#1C464A` is
                // a low-saturation muted teal (HSL 185°, 45%, 20%)
                // that reads as "cool dark gray" at chat-sized type
                // even after fixing contrast for the slightly darker
                // `#F5F5F7` card. WCAG contrast was already ~10:1 —
                // the perceptual problem is hue, not luminance. Same
                // hue (≈187°), saturation pushed 45% → 100%, lightness
                // 20% → 14%: `#004448`. Solves to L_fg ≈ 0.042 against
                // L_bg ≈ 0.914, restoring 10.5:1 against `plain` while
                // actually rendering as teal. Dark canvas matches
                // Xcode's verbatim, so dark uses the plist value as-is.
                return scheme == .dark ? color(0x9ef0dd) : color(0x004448)
            }
            // function_ / bare title → identifier.function (function
            // declaration name, or CSS selector / markdown heading).
            return scheme == .dark ? color(0x67b7a4) : color(0x316d74)

        case "hljs-attr", "hljs-symbol", "hljs-bullet":
            // xcode.syntax.attribute
            return scheme == .dark ? color(0xbf8555) : color(0x815f03)

        case "hljs-template-variable":
            // Bash/shell $VAR-style references — Xcode has no exact
            // analogue; closest semantic is `attribute` (dollar-prefixed
            // macros / preprocessor-ish), so reuse its tint.
            return scheme == .dark ? color(0xbf8555) : color(0x815f03)

        case "hljs-name", "hljs-tag":
            // xcode.syntax.declaration.other (HTML/XML tag names)
            return scheme == .dark ? color(0x41a1c0) : color(0x0f68a0)

        case "hljs-link":
            // xcode.syntax.url
            return scheme == .dark ? color(0x5482fe) : color(0x0e0eff)

        case "hljs-variable", "hljs-params":
            // Parameter / variable names — Xcode without index info
            // leaves these plain, matching the screenshots.
            return plainColor(scheme)

        default:
            return plainColor(scheme)
        }
    }

    static func plainColor(_ scheme: ColorScheme) -> Color {
        // xcode.syntax.plain — Xcode draws this at alpha 0.85; flattened
        // against the canvas (#2A2A2E dark / #F5F5F7 light) for a single
        // opaque hex.
        scheme == .dark ? color(0xdbdbdb) : color(0x262626)
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
