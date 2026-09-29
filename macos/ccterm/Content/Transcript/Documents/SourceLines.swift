import AgentSDK
import Foundation

/// The lines a file document shows, decided from its calls (03-file.md): a
/// change as one unified diff, a new file as its content, a read as the lines
/// the agent saw with their real numbers. Pure — the view draws what is here.
///
/// A change reads the SDK's `structuredPatch` hunks when the result has them,
/// and shows the proposed edit alone (no numbers: where it goes is not known)
/// while the call has no result, or failed, or was denied.
nonisolated struct SourceLines: Sendable, Equatable {
    struct Line: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            case context
            case added
            case removed
            /// Lines left out: `text` says how many, or which.
            case fold
        }

        var kind: Kind
        /// The line's number in the file *after* the change; `nil` for a
        /// removed line and for a proposed edit.
        var number: Int?
        var text: String
        /// UTF-16 ranges of `text` that differ from its counterpart, inside
        /// a changed line.
        var changed: [Range<Int>] = []
    }

    /// A line above the first hunk that says something about the whole.
    struct Note: Sendable, Equatable {
        enum Style: Sendable, Equatable {
            case info
            case error
        }

        var style: Style
        var text: String
    }

    /// The part of a file a read saw.
    struct Slice: Sendable, Equatable {
        var first: Int
        var last: Int
        /// `0` when the result did not say.
        var total: Int
    }

    private(set) var lines: [Line] = []
    private(set) var notes: [Note] = []
    private(set) var slice: Slice?

    var added: Int { lines.filter { $0.kind == .added }.count }
    var removed: Int { lines.filter { $0.kind == .removed }.count }

    /// Where the first change is, as an index into `lines`.
    var firstChange: Int? { lines.firstIndex { $0.kind == .added || $0.kind == .removed } }

    // MARK: - Change

    /// Edits to one file, in the order they were made: each call's hunks in
    /// place. Not merged into one diff — each call's numbers are the file's
    /// as that call left it.
    static func change(_ calls: [ToolCall]) -> SourceLines {
        var result = SourceLines()
        for call in calls { result.append(change: call) }
        result.markChangedCharacters()
        return result
    }

    private mutating func append(change call: ToolCall) {
        switch call.state {
        case .failed(let message):
            notes.append(Note(style: .error, text: Self.firstLine(ofError: message)))
        case .denied:
            notes.append(Note(style: .info, text: String(localized: "Denied")))
        case .interrupted:
            notes.append(Note(style: .info, text: String(localized: "Interrupted")))
        default:
            break
        }
        if let patch = Self.patch(of: call), !patch.hunks.isEmpty {
            if patch.userModified {
                notes.append(Note(style: .info, text: String(localized: "You edited this change before accepting it")))
            }
            if patch.replaceAll { notes.append(Note(style: .info, text: String(localized: "Replace all"))) }
            append(hunks: patch.hunks, original: patch.original)
        } else {
            if call.use.input["replace_all"]?.boolValue == true {
                notes.append(Note(style: .info, text: String(localized: "Replace all")))
            }
            for (old, new) in Self.proposedEdits(of: call) {
                for text in Self.split(old) { lines.append(Line(kind: .removed, number: nil, text: text)) }
                for text in Self.split(new) { lines.append(Line(kind: .added, number: nil, text: text)) }
            }
        }
    }

    private struct Patch {
        var hunks: [DiffHunk]
        var original: String?
        var userModified = false
        var replaceAll = false
    }

    private static func patch(of call: ToolCall) -> Patch? {
        switch call.result?.toolOutcome(Tools.Edit.self) {
        case .success(let output)? where Tools.Edit.matches(call.use.name):
            return Patch(
                hunks: output.structuredPatch, original: output.originalFile, userModified: output.userModified,
                replaceAll: output.replaceAll)
        default: break
        }
        switch call.result?.toolOutcome(Tools.Write.self) {
        case .success(let output)? where Tools.Write.matches(call.use.name) && !output.isNewFile:
            return Patch(hunks: output.structuredPatch, original: output.originalFile)
        default: break
        }
        guard call.use.name != Tools.Edit.name, call.use.name != Tools.Write.name,
            let hunks = try? call.result?.toolUseResult?["structuredPatch"]?.decode([DiffHunk].self)
        else { return nil }
        return Patch(hunks: hunks, original: call.result?.toolUseResult?["originalFile"]?.stringValue)
    }

    /// What a call with no hunks proposes: `(old, new)` text per edit.
    private static func proposedEdits(of call: ToolCall) -> [(String, String)] {
        let input = call.use.input
        switch call.use.name {
        case Tools.Write.name:
            return [("", call.use.input(as: Tools.Write.self)?.content ?? "")]
        case "MultiEdit":
            return (input["edits"]?.arrayValue ?? []).map {
                ($0["old_string"]?.stringValue ?? "", $0["new_string"]?.stringValue ?? "")
            }
        case "NotebookEdit":
            return [("", input["new_source"]?.stringValue ?? "")]
        default:
            return [(input["old_string"]?.stringValue ?? "", input["new_string"]?.stringValue ?? "")]
        }
    }

    private mutating func append(hunks: [DiffHunk], original: String?) {
        var cursor = 1  // the first line of the file not yet accounted for
        for hunk in hunks {
            let start = max(hunk.newStart, 1)
            let gap = start - cursor
            if gap > 0, cursor > 1 || original != nil {
                lines.append(Self.fold(from: cursor, count: gap, counted: original != nil))
            }
            var number = start
            for raw in hunk.lines {
                let text = String(raw.dropFirst())
                switch raw.first {
                case "+":
                    lines.append(Line(kind: .added, number: number, text: text))
                    number += 1
                case "-":
                    lines.append(Line(kind: .removed, number: nil, text: text))
                default:
                    lines.append(Line(kind: .context, number: number, text: text))
                    number += 1
                }
            }
            cursor = number
        }
        if let original {
            let originalCount = Self.lineCount(original)
            let total = originalCount - hunks.map(\.oldLines).reduce(0, +) + hunks.map(\.newLines).reduce(0, +)
            if total >= cursor { lines.append(Self.fold(from: cursor, count: total - cursor + 1, counted: true)) }
        }
    }

    /// *120 lines* when the file's length is known, *Lines 41–86* when only
    /// the hunks are.
    private static func fold(from first: Int, count: Int, counted: Bool) -> Line {
        let text =
            counted
            ? String(localized: "\(count) lines") : String(localized: "Lines \(first)–\(first + count - 1)")
        return Line(kind: .fold, number: nil, text: text)
    }

    /// Within a block of removed lines followed by as many added lines, the
    /// characters that differ pair by pair.
    private mutating func markChangedCharacters() {
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

    // MARK: - New file

    /// The file a Write created, whole.
    static func newFile(_ call: ToolCall) -> SourceLines {
        var result = SourceLines()
        result.appendNotes(for: call)
        let content: String
        if case .success(let output)? = call.result?.toolOutcome(Tools.Write.self) {
            content = output.content
        } else {
            content = call.use.input(as: Tools.Write.self)?.content ?? ""
        }
        result.lines = split(content).enumerated().map { Line(kind: .context, number: $0.offset + 1, text: $0.element) }
        return result
    }

    // MARK: - Read

    /// The lines a Read returned, numbered from where it started.
    static func read(_ call: ToolCall) -> SourceLines {
        var result = SourceLines()
        result.appendNotes(for: call)
        switch call.result?.toolOutcome(Tools.Read.self) {
        case .success(.text(let file))?:
            let text = split(file.content)
            result.lines = text.enumerated().map {
                Line(kind: .context, number: file.startLine + $0.offset, text: $0.element)
            }
            if !text.isEmpty {
                result.slice = Slice(
                    first: file.startLine, last: file.startLine + text.count - 1, total: file.totalLines)
            }
        case .success(.image)?:
            result.notes.append(Note(style: .info, text: String(localized: "This file was read as an image.")))
        case .success(.pdf)?:
            result.notes.append(Note(style: .info, text: String(localized: "This file was read as a PDF.")))
        case .success(.notebook)?:
            result.notes.append(Note(style: .info, text: String(localized: "This file was read as a notebook.")))
        case .success(.unchanged)?:
            result.notes.append(Note(style: .info, text: String(localized: "Unchanged since it was last read.")))
        case .failure(let message)?:
            result.notes.append(Note(style: .error, text: firstLine(ofError: message)))
        default:
            break
        }
        return result
    }

    private mutating func appendNotes(for call: ToolCall) {
        switch call.state {
        case .failed(let message): notes.append(Note(style: .error, text: Self.firstLine(ofError: message)))
        case .denied: notes.append(Note(style: .info, text: String(localized: "Denied")))
        case .interrupted: notes.append(Note(style: .info, text: String(localized: "Interrupted")))
        default: break
        }
    }

    // MARK: - Text

    /// A text's lines; the newline that ends the last does not start another.
    static func split(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private static func lineCount(_ text: String) -> Int { split(text).count }

    /// The CLI's message without its markup, cut to its first line.
    private static func firstLine(ofError message: String) -> String {
        let lines = message.replacingOccurrences(of: "<tool_use_error>", with: "")
            .replacingOccurrences(of: "</tool_use_error>", with: "")
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.first ?? message
    }
}
