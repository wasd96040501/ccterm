import Foundation

/// A command the user ran in the CLI itself — a slash command, or a shell
/// command after `!` — and what it printed: one card, since one without the
/// other reads as half a thing.
nonisolated struct LocalCommand: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case slash
        case shell
    }

    /// `nil` when only the output was recorded.
    var kind: Kind?
    /// As typed: `/model opus`, `git status` (without the `!`).
    var input: String?
    /// As printed, escapes included; the card strips them.
    var output: String
    var errorOutput: String
    var document: ToolDocument?

    /// At most this many lines of output show on the card; the rest open.
    static let previewLimit = 4

    /// Output lines the card shows, which fixes its height.
    var previewLineCount: Int { min(Self.previewLimit, printedLineCount) }

    /// Every line printed, without trailing blank ones.
    var printedLineCount: Int {
        let printed = [output, errorOutput].filter { !$0.isEmpty }.joined(separator: "\n")
        var lines = printed.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.count
    }
}
