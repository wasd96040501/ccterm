import AppKit

extension NSColor {
    /// A form group's fill: black 2.7 % in light, white 4.2 % in dark —
    /// System Settings' grouped-form background.
    static let formGroupFill = NSColor(name: "formGroupFill") { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.042) : NSColor(white: 0, alpha: 0.027)
    }

    /// The hairline between a group's rows: black 3.7 % / white 6 %.
    static let formSeparator = NSColor(name: "formSeparator") { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.037)
    }
}

extension NSAppearance {
    fileprivate var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
