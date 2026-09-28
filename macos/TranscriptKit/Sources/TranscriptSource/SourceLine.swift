import Foundation

/// One line of a ``SourceDocument``: its text, where it sits in the file, and
/// how it takes part in a comparison.
public struct SourceLine: Sendable, Equatable {
    /// What the line is to a comparison. A plain file is all ``unchanged``.
    public enum Change: Sendable, Equatable {
        case unchanged
        /// In the new file only. Drawn on Xcode's green, numbered.
        case added
        /// In the old file only. Drawn on Xcode's red with no number, the way
        /// Xcode's inline comparison shows a line the file no longer has.
        case removed
        /// Unchanged lines a diff left out, between two of its hunks: one
        /// blank, unnumbered line, as Xcode marks a folded region.
        case elided
    }

    /// The line without its terminator.
    public var text: String
    public var change: Change
    /// The number shown in the gutter; `nil` shows none.
    public var number: Int?
    /// Character ranges (UTF-16 offsets into ``text``) that changed within an
    /// ``Change/added`` line — the word-level highlight a paired edit gets.
    public var changedRanges: [Range<Int>]
    /// Explicit colours, such as a command's ANSI escapes, drawn instead of
    /// syntax colours over their ranges.
    public var styles: [SourceStyleRun]

    public init(
        text: String, change: Change = .unchanged, number: Int? = nil, changedRanges: [Range<Int>] = [],
        styles: [SourceStyleRun] = []
    ) {
        self.text = text
        self.change = change
        self.number = number
        self.changedRanges = changedRanges
        self.styles = styles
    }
}

/// A span of a line drawn in a colour of its own rather than a syntax colour.
public struct SourceStyleRun: Sendable, Equatable {
    /// The colours a terminal names, resolved to system colours at draw time.
    public enum Color: Sendable, Equatable {
        case black, red, green, yellow, blue, magenta, cyan, white
        case brightBlack, brightRed, brightGreen, brightYellow, brightBlue, brightMagenta, brightCyan, brightWhite
        /// A 24-bit colour (`38;2;r;g;b`, or a 256-colour index resolved to one).
        case rgb(UInt8, UInt8, UInt8)
    }

    /// UTF-16 offsets into the line's text.
    public var range: Range<Int>
    public var foreground: Color?
    public var background: Color?
    public var isBold: Bool
    public var isDim: Bool
    public var isItalic: Bool
    public var isUnderlined: Bool

    public init(
        range: Range<Int>, foreground: Color? = nil, background: Color? = nil, isBold: Bool = false,
        isDim: Bool = false, isItalic: Bool = false, isUnderlined: Bool = false
    ) {
        self.range = range
        self.foreground = foreground
        self.background = background
        self.isBold = isBold
        self.isDim = isDim
        self.isItalic = isItalic
        self.isUnderlined = isUnderlined
    }
}
