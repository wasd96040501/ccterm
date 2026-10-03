import Foundation

/// Something the reader did to the CLI rather than said to the model: a
/// slash command or a `!` shell command, with what it printed
/// (design/transcript/05-local.md). Drawn as the reader's bubble with the command as a token, and what it printed under it.
///
/// `/compact` and `/exit` never become one: they fold into the
/// `SessionDivider` they mark.
nonisolated struct LocalCommand: Sendable, Equatable, Identifiable {
    let id: String
    let command: Command
    /// What it printed on standard output — empty while it has printed
    /// nothing, or when it never does.
    var output: String
    var errorOutput: String

    enum Command: Sendable, Equatable {
        /// `/model` with arguments `opus`. The name keeps its slash.
        case slash(name: String, arguments: String)
        /// A `!` command, without the `!`.
        case shell(String)
    }
}

/// The words under the bubble (05-local.md): the command, its arguments, and what
/// it printed — one or two lines under it, or, for a `!` command whose output
/// runs longer, how long it was.
nonisolated extension LocalCommand {
    /// `/model`; a skill's short name (`/skill-creator` for
    /// `/skill-creator:skill-creator`); a `!` command's command line.
    var title: String {
        switch command {
        case .slash(let name, _):
            guard let colon = name.lastIndex(of: ":") else { return name }
            return "/" + name[name.index(after: colon)...]
        case .shell(let line): return line
        }
    }

    /// The whole name, as the tooltip, when `title` shortened it.
    var fullName: String? {
        if case .slash(let name, _) = command, name != title { name } else { nil }
    }

    /// A slash command's arguments, in label colour after its name.
    var arguments: String {
        if case .slash(_, let arguments) = command { arguments } else { "" }
    }

    /// Output shows as its errors, in red, when it wrote only to stderr.
    var outputIsError: Bool { output.isEmpty && !errorOutput.isEmpty }

    /// What shows under the bubble: at most two lines of a slash command's
    /// output, one of a `!` command's. `nil` when there is none, or when a `!`
    /// command's output runs longer (then `lineCount` says how long).
    var inlineOutput: String? {
        let lines = printedLines
        guard !lines.isEmpty, lineCount == nil else { return nil }
        // A blank second line (`/context`'s gap under its total) is no line to show.
        var shown = Array(lines.prefix(Self.inlineLines))
        while shown.last?.allSatisfy(\.isWhitespace) == true { shown.removeLast() }
        return shown.isEmpty ? nil : shown.joined(separator: "\n")
    }

    /// A slash command's output ran past two lines: *Show all* opens it beside.
    var isOutputCut: Bool {
        if case .slash = command { printedLines.count > Self.inlineLines } else { false }
    }

    /// *12 lines*, under the bubble of a `!` command that printed more than
    /// one; it opens the command document beside.
    var lineCount: String? {
        guard case .shell = command, printedLines.count > 1 else { return nil }
        return String(localized: "\(printedLines.count) lines")
    }

    private static let inlineLines = 2

    private var printedLines: [String] {
        let text = (outputIsError ? errorOutput : output).trimmingCharacters(in: .newlines)
        return text.isEmpty ? [] : text.components(separatedBy: "\n")
    }
}
