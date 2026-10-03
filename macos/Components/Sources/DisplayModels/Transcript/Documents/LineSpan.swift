import Foundation

/// A stretch of one line that is set apart — a keyword, a string, an ANSI
/// colour — as the pure highlighters and the ANSI reader report it. The view
/// that draws a line picks the colour and weight for each style
/// (`NumberedLinesView`, `CommandHeaderView`); nothing here knows AppKit.
public nonisolated struct LineSpan: Sendable, Equatable {
    public enum Style: Sendable, Equatable {
        // Source and shell, in the transcript code card's palette.
        case keyword
        case string
        case comment
        case number
        case type
        case function
        // ANSI SGR, as the command output maps it.
        case bold
        case green
        case red
        case boldGreen
    }

    /// UTF-16 offsets within the line, as `NSRange` counts them.
    public var range: Range<Int>
    public var style: Style

    public init(range: Range<Int>, style: Style) {
        self.range = range
        self.style = style
    }
}
