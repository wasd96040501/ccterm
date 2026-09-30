import Foundation

/// A line of the transcript's work voice, with the few distinctions the views
/// draw in it — and nothing about how they draw them.
///
/// The words are decided here, localized, from the model; the fonts and
/// colours are the row view's. So a sentence like *Edited **A.swift**, ran 3
/// commands* is testable without AppKit, and a view never composes wording.
nonisolated struct StyledText: Sendable, Equatable {
    struct Run: Sendable, Equatable {
        var text: String
        var style: Style
    }

    enum Style: Sendable, Equatable {
        /// The line's own colour: secondary in a work line.
        case plain
        /// A thing the reader scans for — a file, a host — in label colour.
        /// `opens` is the id of what it opens beside (`TranscriptPage.document(for:)`),
        /// making it a link; `nil` when it only stands out.
        case noun(opens: String?)
        /// A pattern or a path: monospaced, the inline-code colour.
        case code
        /// Lines added, in green.
        case added
        /// Lines removed, in red.
        case removed
        /// Something that went wrong, in red.
        case failure
    }

    private(set) var runs: [Run]

    init() {
        runs = []
    }

    init(_ text: String, style: Style = .plain) {
        runs = text.isEmpty ? [] : [Run(text: text, style: style)]
    }

    /// `+12 −3`, green and red — a change's stat wherever it shows.
    static func diffStat(added: Int, removed: Int) -> StyledText {
        StyledText("+\(added)", style: .added) + StyledText(" ") + StyledText("−\(removed)", style: .removed)
    }

    /// Localized words with styled arguments in them. Interpolate `slot(n)`
    /// where argument `n` goes; a translation may move the slots, and each is
    /// replaced by its argument wherever it lands:
    ///
    /// ```swift
    /// StyledText(localized: String(localized: "Edited \(StyledText.slot(0))"), file)
    /// ```
    ///
    /// Slots rather than `%@` parsed out of a localized string: a literal with
    /// no arguments is not a format, and `String(localized:)` escapes its `%`.
    init(localized: String, _ arguments: StyledText...) {
        self.init(localized: localized, arguments: arguments)
    }

    init(localized: String, arguments: [StyledText]) {
        runs = []
        var pending = ""
        for character in localized {
            if let index = Self.slotIndex(character), index < arguments.count {
                append(StyledText(pending))
                pending = ""
                append(arguments[index])
            } else {
                pending.append(character)
            }
        }
        append(StyledText(pending))
    }

    /// Where argument `index` goes in a localized string: one private-use
    /// character, which no translation contains otherwise.
    static func slot(_ index: Int) -> String {
        String(Character(UnicodeScalar(slotBase + UInt32(index))!))
    }

    private static let slotBase: UInt32 = 0xE000

    private static func slotIndex(_ character: Character) -> Int? {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first,
            (slotBase..<slotBase + 16).contains(scalar.value)
        else { return nil }
        return Int(scalar.value - slotBase)
    }

    var isEmpty: Bool { runs.isEmpty }

    /// The words alone — for accessibility, tooltips and tests.
    var string: String { runs.map(\.text).joined() }

    mutating func append(_ other: StyledText) {
        for run in other.runs {
            if let last = runs.last, last.style == run.style {
                runs[runs.count - 1].text += run.text
            } else {
                runs.append(run)
            }
        }
    }

    static func + (lhs: StyledText, rhs: StyledText) -> StyledText {
        var result = lhs
        result.append(rhs)
        return result
    }

    /// `parts` joined by `separator`, empty parts skipped.
    static func joined(_ parts: [StyledText], separator: String) -> StyledText {
        var result = StyledText()
        for part in parts where !part.isEmpty {
            if !result.isEmpty { result.append(StyledText(separator)) }
            result.append(part)
        }
        return result
    }
}
