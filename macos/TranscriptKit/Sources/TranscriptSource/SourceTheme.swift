import AppKit

/// Xcode's Default (Light) and Default (Dark) themes.
///
/// The syntax colours, fonts and line spacing are the values in Xcode's own
/// `Default (Light).xccolortheme` / `Default (Dark).xccolortheme`
/// (`SourceEditor.framework/Resources`), not estimates. The comparison tints
/// and the change bar aren't in a theme file; they were sampled from Xcode's
/// inline comparison as the window server composited it (light). The dark tints
/// are the light ones' proportion of the system green / red over the dark
/// background.
///
/// Colours are dynamic, so a view drawing them follows its appearance with no
/// work. Fonts are not — the light theme sets SF Mono Regular with Semibold
/// keywords, the dark one Medium with Bold — so ``font(for:dark:)`` takes the
/// appearance and a view re-styles when it changes.
enum SourceTheme {
    /// `DVTLineSpacing`.
    static let lineSpacing: CGFloat = 1.1
    static let fontSize: CGFloat = 12

    // MARK: - Editor

    static let background = dynamic(light: rgb(1, 1, 1), dark: rgb(0.120543, 0.122844, 0.141312))
    static let plainText = dynamic(light: rgb(0, 0, 0, 0.85), dark: rgb(1, 1, 1, 0.85))
    static let selection = dynamic(
        light: rgb(0.642038, 0.802669, 0.999195), dark: rgb(0.317647, 0.356862, 0.439215))
    static let lineNumber = dynamic(light: hex(0xA6A6A6), dark: hex(0x6C6C72))

    // MARK: - Comparison

    static let addedBackground = dynamic(light: hex(0xECFBF0), dark: hex(0x213129))
    static let removedBackground = dynamic(light: hex(0xFCF5F3), dark: hex(0x332226))
    /// The word-level highlight inside an added line.
    static let addedWordBackground = dynamic(light: hex(0xD1F6DB), dark: hex(0x23462F))
    /// The gutter bar beside a change, drawn with lighter diagonal stripes.
    static let changeBar = dynamic(light: hex(0x499BF9), dark: hex(0x3A86E8))
    static let changeBarStripe = dynamic(light: hex(0xB5D3FA), dark: hex(0x2A5F9E))
    static let elidedBackground = dynamic(light: rgb(0, 0, 0, 0.04), dark: rgb(1, 1, 1, 0.05))

    // MARK: - Syntax

    static func color(for kind: SourceToken.Kind) -> NSColor {
        switch kind {
        case .keyword: keyword
        case .string: string
        case .number: number
        case .comment, .documentationComment: comment
        case .mark: mark
        case .attribute: attribute
        case .preprocessor: preprocessor
        case .declarationType: declarationType
        case .declarationOther: declarationOther
        case .systemType: systemType
        }
    }

    private static let keyword = dynamic(
        light: rgb(0.607592, 0.137526, 0.576284), dark: rgb(0.988394, 0.37355, 0.638329))
    private static let string = dynamic(light: rgb(0.77, 0.102, 0.086), dark: rgb(0.989117, 0.41558, 0.365684))
    private static let number = dynamic(light: rgb(0.11, 0, 0.81), dark: rgb(0.814983, 0.749393, 0.412334))
    private static let comment = dynamic(
        light: rgb(0.36526, 0.421879, 0.475154), dark: rgb(0.423943, 0.474618, 0.525183))
    private static let mark = dynamic(light: rgb(0.290196, 0.333333, 0.376471), dark: rgb(0.572549, 0.631373, 0.694118))
    private static let attribute = dynamic(
        light: rgb(0.505801, 0.371396, 0.012096), dark: rgb(0.74902, 0.521569, 0.333333))
    private static let preprocessor = dynamic(
        light: rgb(0.391471, 0.220311, 0.124457), dark: rgb(0.991311, 0.560764, 0.246107))
    private static let declarationType = dynamic(
        light: rgb(0.0431373, 0.309804, 0.47451), dark: rgb(0.362946, 0.846428, 0.998966))
    private static let declarationOther = dynamic(
        light: rgb(0.0588235, 0.407843, 0.627451), dark: rgb(0.254902, 0.631373, 0.752941))
    private static let systemType = dynamic(light: rgb(0.224543, 0, 0.628029), dark: rgb(0.815686, 0.658824, 1))

    // MARK: - Fonts

    /// The plain face: SF Mono Regular in light, Medium in dark.
    static func font(dark: Bool) -> NSFont {
        .monospacedSystemFont(ofSize: fontSize, weight: dark ? .medium : .regular)
    }

    static func font(for kind: SourceToken.Kind?, dark: Bool) -> NSFont {
        switch kind {
        case .keyword?: .monospacedSystemFont(ofSize: fontSize, weight: dark ? .bold : .semibold)
        case .mark?: .monospacedSystemFont(ofSize: fontSize, weight: .bold)
        case .documentationComment?:
            NSFont(name: dark ? "Helvetica" : "HelveticaNeue", size: fontSize) ?? .systemFont(ofSize: fontSize)
        default: font(dark: dark)
        }
    }

    // MARK: - Terminal colours

    /// A terminal's named colours as system colours, so output stays legible
    /// on either background: black and white, which vanish on one of them,
    /// read as the label colours.
    static func color(for color: SourceStyleRun.Color) -> NSColor {
        switch color {
        case .black: .labelColor
        case .red, .brightRed: .systemRed
        case .green, .brightGreen: .systemGreen
        case .yellow, .brightYellow: terminalYellow
        case .blue, .brightBlue: .systemBlue
        case .magenta, .brightMagenta: .systemPurple
        case .cyan, .brightCyan: .systemTeal
        case .white, .brightWhite: .labelColor
        case .brightBlack: .secondaryLabelColor
        case .rgb(let r, let g, let b):
            NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
    }

    /// `systemYellow` is unreadable as text on white; light takes a darker gold.
    private static let terminalYellow = dynamic(light: hex(0x9A7300), dark: NSColor.systemYellow)

    // MARK: - Building

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    private static func hex(_ value: UInt32) -> NSColor {
        rgb(CGFloat((value >> 16) & 0xFF) / 255, CGFloat((value >> 8) & 0xFF) / 255, CGFloat(value & 0xFF) / 255)
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.isDark ? dark : light
        }
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
