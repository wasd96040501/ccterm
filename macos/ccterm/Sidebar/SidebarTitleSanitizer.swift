import Foundation

extension String {
    /// Project a free-form title onto a clean single-line form for
    /// display in an `NSTextField` that runs in single-line mode.
    ///
    /// `NSTextField`'s `usesSingleLineMode = true` only controls *input*
    /// layout (typing / pasting) — it does NOT strip any of these from
    /// a string assigned via `stringValue`. Session titles derived from
    /// a multi-paragraph first user message or pasted code carry real
    /// `\n` / `\t` / formatting controls; without sanitizing them here
    /// every offending character either expands the cell past its
    /// `heightOfRowByItem` (newlines, vertical tabs, form feeds) or
    /// renders as an invisible / `.notdef` box glyph (zero-width
    /// formatting, U+FFFC).
    ///
    /// Sanitization rules:
    ///
    /// - Any Unicode whitespace-or-newline run (covers `\n` `\r` `\r\n`
    ///   `\t` U+0085 NEL U+2028 LS U+2029 PS U+000B VT U+000C FF and
    ///   ordinary spaces) → single ASCII space.
    /// - ASCII control characters not already in the whitespace set
    ///   (`\0` through `\u{1F}` minus `\t`, plus `\u{7F}` DEL) →
    ///   dropped.
    /// - Zero-width / bidi formatting controls that would otherwise
    ///   render as `.notdef` boxes or silently shift the run's
    ///   directionality (`U+200B…U+200D` zero-width space / non-joiner /
    ///   joiner, `U+2060` word joiner, `U+2066…U+2069` LRI / RLI / FSI /
    ///   PDI, `U+FEFF` BOM, `U+FFFC` OBJECT REPLACEMENT CHARACTER) →
    ///   dropped.
    /// - Leading and trailing spaces (after the above mapping) →
    ///   trimmed.
    ///
    /// Pure-display normalization; the original `Session.title` /
    /// `SessionRecord.title` is preserved at the model layer for
    /// matching / search / accessibility callers that may want the raw
    /// text.
    func collapsedSingleLineForDisplay() -> String {
        let whitespace = CharacterSet.whitespacesAndNewlines
        // `controlCharacters` includes `\n` / `\r` / `\t` etc., which
        // we want collapsed to a space rather than dropped — subtract
        // whitespace from it before dropping. The zero-width /
        // formatting set must NOT have whitespace subtracted: Foundation
        // counts U+200B (ZERO WIDTH SPACE) and U+FEFF (BOM) as
        // whitespace, but visually they're invisible and need to be
        // dropped outright, not folded into a real space.
        let droppable = Self.zeroWidthAndFormattingControls
            .union(CharacterSet.controlCharacters.subtracting(whitespace))
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(unicodeScalars.count)
        var lastWasSpace = true  // start true so leading whitespace is trimmed
        for scalar in unicodeScalars {
            if droppable.contains(scalar) { continue }
            if whitespace.contains(scalar) {
                if !lastWasSpace {
                    scalars.append(Unicode.Scalar(0x20))
                    lastWasSpace = true
                }
            } else {
                scalars.append(scalar)
                lastWasSpace = false
            }
        }
        var result = String(scalars)
        while result.last == " " { result.removeLast() }
        return result
    }

    private static let zeroWidthAndFormattingControls: CharacterSet = {
        CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}\u{FFFC}")
            .union(CharacterSet(charactersIn: "\u{2066}\u{2067}\u{2068}\u{2069}"))
    }()
}
