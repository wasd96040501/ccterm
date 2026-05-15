import AppKit

/// Per-kind highlight planning for `ToolGroupBlock.Child`. Parallel to
/// `ToolGroupChildLayout` — the layout enum decides how to *draw* a
/// child, this one decides what *highlight payload* to request and how
/// to fold the JS results into a `HighlightValue` for storage.
///
/// This file is a pure dispatcher — every per-kind plan lives in its
/// own child folder alongside that child's layout (e.g.
/// `FileEdit/FileEditChildHighlight.swift`). Adding a new
/// highlight-bearing child kind is one switch arm here plus the new
/// plan implementation in that kind's folder.
///
/// `requests(for:)` returns `nil` when a child kind has no highlight
/// contribution; the storage skips it without enlarging the JS batch.
enum ToolGroupChildHighlight {
    /// One child's highlight request slice plus the `finalize` closure
    /// that turns the matching results back into a single
    /// `HighlightValue`. The storage fans every child's `payload` into
    /// a shared JS batch, then walks back through `finalize` to write
    /// per-child values keyed by `child.id`.
    struct Plan {
        let payload: [(code: String, lang: String?)]
        let finalize: ([[SyntaxToken]]) -> HighlightValue?
    }

    static func requests(for child: ToolGroupBlock.Child) -> Plan? {
        switch child {
        case .fileEdit(let c):
            return FileEditChildHighlight.plan(c)
        case .bash(let c):
            return BashChildHighlight.plan(c)
        case .grep, .glob, .webFetch, .webSearch,
             .askUserQuestion, .agent:
            // These bodies render plain text — no syntax highlight today.
            return nil
        case .read, .generic:
            // Header-only kinds — no body glyphs to tokenize.
            return nil
        }
    }
}
