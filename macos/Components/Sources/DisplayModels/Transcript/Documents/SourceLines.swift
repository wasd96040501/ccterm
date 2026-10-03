import Foundation

/// The lines a file document shows (03-file.md): a change as one unified diff,
/// a new file as its content, a read as the lines the agent saw with their real
/// numbers. Pure — the view draws what is here; the app decides the lines from
/// the calls (`SourceLines+Call`).
public nonisolated struct SourceLines: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case context
            case added
            case removed
            /// Lines left out: `text` says how many, or which.
            case fold
        }

        public var kind: Kind
        /// The line's number in the file *after* the change; `nil` for a
        /// removed line and for a proposed edit.
        public var number: Int?
        public var text: String
        /// UTF-16 ranges of `text` that differ from its counterpart, inside
        /// a changed line.
        public var changed: [Range<Int>] = []

        public init(kind: Kind, number: Int? = nil, text: String, changed: [Range<Int>] = []) {
            self.kind = kind
            self.number = number
            self.text = text
            self.changed = changed
        }
    }

    /// A line above the first hunk that says something about the whole.
    public struct Note: Sendable, Equatable {
        public enum Style: Sendable, Equatable {
            case info
            case error
        }

        public var style: Style
        public var text: String

        public init(style: Style, text: String) {
            self.style = style
            self.text = text
        }
    }

    /// The part of a file a read saw.
    public struct Slice: Sendable, Equatable {
        public var first: Int
        public var last: Int
        /// `0` when the result did not say.
        public var total: Int

        public init(first: Int, last: Int, total: Int) {
            self.first = first
            self.last = last
            self.total = total
        }
    }

    public var lines: [Line]
    public var notes: [Note]
    public var slice: Slice?

    public init(lines: [Line] = [], notes: [Note] = [], slice: Slice? = nil) {
        self.lines = lines
        self.notes = notes
        self.slice = slice
    }

    public var added: Int { lines.filter { $0.kind == .added }.count }
    public var removed: Int { lines.filter { $0.kind == .removed }.count }

    /// Where the first change is, as an index into `lines`.
    public var firstChange: Int? { lines.firstIndex { $0.kind == .added || $0.kind == .removed } }

    // MARK: - Change

    /// Within a block of removed lines followed by as many added lines, the
    /// characters that differ pair by pair.
    public mutating func markChangedCharacters() {
        var index = 0
        while index < lines.count {
            guard lines[index].kind == .removed else {
                index += 1
                continue
            }
            var end = index
            while end < lines.count, lines[end].kind == .removed { end += 1 }
            var addedEnd = end
            while addedEnd < lines.count, lines[addedEnd].kind == .added { addedEnd += 1 }
            if end - index == addedEnd - end {
                for offset in 0..<(end - index) {
                    let (old, new) = Self.difference(lines[index + offset].text, lines[end + offset].text)
                    lines[index + offset].changed = old
                    lines[end + offset].changed = new
                }
            }
            index = max(addedEnd, index + 1)
        }
    }

    /// The middle of two lines that their common start and end leave: `[]`
    /// on a side where that is empty or the whole line.
    private static func difference(_ old: String, _ new: String) -> ([Range<Int>], [Range<Int>]) {
        let a = Array(old.utf16)
        let b = Array(new.utf16)
        var prefix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        guard prefix + suffix > 0 else { return ([], []) }
        func middle(_ units: [UInt16]) -> [Range<Int>] {
            let range = prefix..<(units.count - suffix)
            return range.isEmpty ? [] : [range]
        }
        return (middle(a), middle(b))
    }
}
