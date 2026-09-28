import Foundation

/// What a ``SourceView`` shows: lines, each with its number and its part in a
/// comparison, and the language that colours them.
///
/// A plain file and a comparison are the same thing here — a comparison is a
/// file some of whose lines are added or removed — so one view draws both, the
/// way Xcode's editor draws a file and its inline comparison.
public struct SourceDocument: Sendable, Equatable {
    public var lines: [SourceLine]
    public var language: SourceLanguage

    public init(lines: [SourceLine], language: SourceLanguage) {
        self.lines = lines
        self.language = language
    }

    /// A file, or the part of one that starts at `firstLine`; `nil` numbers
    /// nothing.
    public init(text: String, firstLine: Int? = 1, language: SourceLanguage) {
        lines = text.sourceLines.enumerated().map { index, text in
            SourceLine(text: text, number: firstLine.map { $0 + index })
        }
        self.language = language
    }

    /// Command output: ANSI colours kept, everything else escaped away.
    public init(terminalOutput: String) {
        lines = ANSIText.lines(of: terminalOutput)
        language = .plainText
    }

    /// `old` and `new` compared line by line. `firstLine` is where `new`
    /// starts in its file, or `nil` when that isn't known and nothing should
    /// be numbered.
    public init(old: String, new: String, firstLine: Int? = 1, language: SourceLanguage) {
        let oldLines = old.sourceLines
        let newLines = new.sourceLines
        lines = Self.compare(oldLines, newLines, firstNewLine: firstLine)
        self.language = language
        markChangedWords()
    }

    /// A unified diff's hunks. With `original` — the whole file before the
    /// change — the hunks are applied over it and the whole file shows, as in
    /// Xcode; without it, only the hunks, a ``SourceLine/Change/elided`` line
    /// standing for what lies between them.
    public init(hunks: [SourceDiffHunk], original: String? = nil, language: SourceLanguage) {
        self.language = language
        lines = []
        let originalLines = original?.sourceLines
        var oldLine = 1  // 1-based cursor into the original
        var newLine = 1
        for (index, hunk) in hunks.enumerated() {
            if let originalLines {
                // The unchanged stretch before this hunk.
                while oldLine < hunk.oldStart, oldLine - 1 < originalLines.count {
                    lines.append(SourceLine(text: originalLines[oldLine - 1], number: newLine))
                    oldLine += 1
                    newLine += 1
                }
            } else if index > 0 || hunk.newStart > 1 {
                lines.append(SourceLine(text: "", change: .elided))
            }
            oldLine = hunk.oldStart
            newLine = hunk.newStart
            for raw in hunk.lines {
                let marker = raw.first
                let text = String(raw.dropFirst())
                switch marker {
                case "+":
                    lines.append(SourceLine(text: text, change: .added, number: newLine))
                    newLine += 1
                case "-":
                    lines.append(SourceLine(text: text, change: .removed))
                    oldLine += 1
                case "\\":
                    break  // "\ No newline at end of file"
                default:
                    lines.append(SourceLine(text: text, number: newLine))
                    oldLine += 1
                    newLine += 1
                }
            }
            // A hunk that counted lines oldLines past its start moved the
            // cursor by the same amount; trust the header over the lines.
            oldLine = max(oldLine, hunk.oldStart + hunk.oldLines)
        }
        if let originalLines {
            while oldLine - 1 < originalLines.count {
                lines.append(SourceLine(text: originalLines[oldLine - 1], number: newLine))
                oldLine += 1
                newLine += 1
            }
        } else if !hunks.isEmpty {
            lines.append(SourceLine(text: "", change: .elided))
        }
        markChangedWords()
    }

    // MARK: - Reading

    /// Each run of consecutive added or removed lines — what Xcode counts as
    /// one change and steps between — as a range of line indexes.
    public var changes: [Range<Int>] {
        var result: [Range<Int>] = []
        var start: Int?
        for (index, line) in lines.enumerated() {
            let changed = line.change == .added || line.change == .removed
            if changed, start == nil { start = index }
            if !changed, let begun = start {
                result.append(begun..<index)
                start = nil
            }
        }
        if let start { result.append(start..<lines.count) }
        return result
    }

    public var insertions: Int { lines.filter { $0.change == .added }.count }
    public var deletions: Int { lines.filter { $0.change == .removed }.count }

    // MARK: - Comparing

    /// Lines of `new`, with the lines of `old` it doesn't have interleaved
    /// where they were: removals ahead of insertions in each run, as Xcode
    /// lays out an inline comparison.
    static func compare(_ old: [String], _ new: [String], firstNewLine: Int?) -> [SourceLine] {
        let difference = new.difference(from: old)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var lines: [SourceLine] = []
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                lines.append(SourceLine(text: old[i], change: .removed))
                i += 1
            } else if j < new.count, inserted.contains(j) {
                lines.append(SourceLine(text: new[j], change: .added, number: firstNewLine.map { $0 + j }))
                j += 1
            } else if j < new.count {
                lines.append(SourceLine(text: new[j], number: firstNewLine.map { $0 + j }))
                i += 1
                j += 1
            } else {
                i += 1
            }
        }
        return lines
    }

    /// Word-level highlights on added lines, Xcode's: in a run where lines
    /// were removed and added, the n-th added line is compared with the n-th
    /// removed one and what it doesn't share is marked; an added line with no
    /// partner is marked whole. A run of only additions is marked nowhere —
    /// with nothing to compare against, the green says it all.
    private mutating func markChangedWords() {
        for change in changes {
            let removed = change.filter { lines[$0].change == .removed }
            let added = change.filter { lines[$0].change == .added }
            guard !removed.isEmpty, !added.isEmpty else { continue }
            for (n, index) in added.enumerated() {
                let text = lines[index].text
                if n < removed.count {
                    lines[index].changedRanges = Self.changedRanges(in: text, comparedWith: lines[removed[n]].text)
                } else if !text.isEmpty {
                    lines[index].changedRanges = [0..<text.utf16.count]
                }
            }
        }
    }

    /// The UTF-16 ranges of `new` whose words `old` doesn't have in that
    /// order. Words are runs of letters and digits; every other character is
    /// a word of its own. Adjacent marks merge, across the spaces between them.
    static func changedRanges(in new: String, comparedWith old: String) -> [Range<Int>] {
        let newWords = new.words
        let oldWords = old.words
        guard newWords.count * oldWords.count < 250_000 else { return [0..<new.utf16.count] }
        let difference = newWords.map(\.text).difference(from: oldWords.map(\.text))
        var ranges: [Range<Int>] = []
        for case .insert(let offset, _, _) in difference {
            let range = newWords[offset].range
            if let last = ranges.last, Self.onlySpaces(in: new, between: last.upperBound, and: range.lowerBound) {
                ranges[ranges.count - 1] = last.lowerBound..<range.upperBound
            } else {
                ranges.append(range)
            }
        }
        return ranges.sorted { $0.lowerBound < $1.lowerBound }
    }

    private static func onlySpaces(in text: String, between start: Int, and end: Int) -> Bool {
        guard start <= end else { return false }
        let units = Array(text.utf16)[start..<end]
        return units.allSatisfy { $0 == 0x20 || $0 == 0x09 }
    }
}

/// One hunk of a unified diff: where it starts on each side, and its lines,
/// each prefixed with `" "`, `"-"` or `"+"`.
public struct SourceDiffHunk: Sendable, Equatable {
    public var oldStart: Int
    public var oldLines: Int
    public var newStart: Int
    public var newLines: Int
    public var lines: [String]

    public init(oldStart: Int, oldLines: Int, newStart: Int, newLines: Int, lines: [String]) {
        self.oldStart = oldStart
        self.oldLines = oldLines
        self.newStart = newStart
        self.newLines = newLines
        self.lines = lines
    }
}

extension String {
    /// Lines without terminators; a trailing newline ends the last line
    /// rather than starting an empty one.
    var sourceLines: [String] {
        var lines = components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        return lines
    }

    /// Words for a word-level comparison, with their UTF-16 ranges.
    fileprivate var words: [(text: Substring, range: Range<Int>)] {
        var result: [(Substring, Range<Int>)] = []
        var offset = 0
        var index = startIndex
        while index < endIndex {
            let character = self[index]
            var end = self.index(after: index)
            if character.isLetter || character.isNumber || character == "_" {
                while end < endIndex, self[end].isLetter || self[end].isNumber || self[end] == "_" {
                    end = self.index(after: end)
                }
            }
            let word = self[index..<end]
            let length = word.utf16.count
            if !(character == " " || character == "\t") {
                result.append((word, offset..<offset + length))
            }
            offset += length
            index = end
        }
        return result
    }
}
