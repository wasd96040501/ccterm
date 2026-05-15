import AppKit

/// Highlight planning for `BashChild` — one tokenisation pass over the
/// command text using highlight.js's `bash` grammar. Matches the
/// existing fenced-code-block path so a `bash` command card and a
/// triple-backtick `bash` fence read at the same tonal tier.
///
/// Stdout / stderr are **not** tokenised — they're rendered through
/// `ANSIAttributedBuilder`, which gives terminal output the same SGR
/// palette the React side uses for `.bash-block` output. Syntax
/// highlighting would fight ANSI colours anyway (the stream is raw,
/// not a code excerpt).
enum BashChildHighlight {
    static func plan(_ child: BashChild) -> ToolGroupChildHighlight.Plan? {
        let trimmed = child.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return ToolGroupChildHighlight.Plan(
            payload: [(child.command, "bash")],
            finalize: { results in
                guard let tokens = results.first, !tokens.isEmpty else { return nil }
                return .tokens(tokens)
            })
    }
}
