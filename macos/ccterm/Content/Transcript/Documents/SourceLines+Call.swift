import AgentSDK
import DisplayModels
import Foundation

/// The lines of a file document, decided from its calls (03-file.md): a change
/// as one unified diff, a new file as its content, a read as the lines the
/// agent saw with their real numbers.
///
/// A change reads the SDK's `structuredPatch` hunks when the result has them,
/// and shows the proposed edit alone (no numbers: where it goes is not known)
/// while the call has no result, or failed, or was denied.
nonisolated extension SourceLines {
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
                for text in old.lines { lines.append(Line(kind: .removed, number: nil, text: text)) }
                for text in new.lines { lines.append(Line(kind: .added, number: nil, text: text)) }
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
            let originalCount = original.lines.count
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
        result.lines = content.lines.enumerated().map { Line(kind: .context, number: $0.offset + 1, text: $0.element) }
        return result
    }

    // MARK: - Read

    /// The lines a Read returned, numbered from where it started.
    static func read(_ call: ToolCall) -> SourceLines {
        var result = SourceLines()
        result.appendNotes(for: call)
        switch call.result?.toolOutcome(Tools.Read.self) {
        case .success(.text(let file))?:
            let text = file.content.lines
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

    /// The CLI's message without its markup, cut to its first line.
    private static func firstLine(ofError message: String) -> String {
        let lines = message.replacingOccurrences(of: "<tool_use_error>", with: "")
            .replacingOccurrences(of: "</tool_use_error>", with: "")
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.first ?? message
    }
}
