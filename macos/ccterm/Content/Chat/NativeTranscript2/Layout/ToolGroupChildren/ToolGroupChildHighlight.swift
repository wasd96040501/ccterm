import AppKit

/// Per-kind highlight planning for `ToolGroupBlock.Child`. Parallel to
/// `ToolGroupChildLayout` — the layout enum decides how to *draw* a
/// child, this one decides what *highlight payload* to request and how
/// to fold the JS results into a `HighlightValue` for storage.
///
/// `requests(for:)` returns `nil` when a child kind has no highlight
/// contribution; the storage skips it without enlarging the JS batch.
///
/// ### Adding a new child kind that needs highlight
///
/// One `case` here. Children that don't need highlight don't need a
/// case at all — the default `return nil` covers them.
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
            return fileEditPlan(c)
        }
    }

    // MARK: - Per-kind plans

    /// Per-unique-line tokenisation. Highlight loses cross-line context
    /// (each line is tokenised on its own) — the same simplification
    /// the old `NativeDiffView` made for the same reason: it lets us
    /// key the resulting `[content: tokens]` map by raw line content,
    /// so the draw pass can look up tokens regardless of which hunk an
    /// identical line lives in. Empty lines are skipped to keep the JS
    /// payload small.
    private static func fileEditPlan(_ child: FileEditChild) -> Plan? {
        let lang = LanguageDetection.language(for: child.filePath)
        var seen = Set<String>()
        var unique: [String] = []
        for line in child.diff.lines where !line.isEmpty {
            if seen.insert(line).inserted { unique.append(line) }
        }
        guard !unique.isEmpty else { return nil }
        return Plan(
            payload: unique.map { ($0, lang) },
            finalize: { results in
                var map: [String: [SyntaxToken]] = [:]
                for (content, tokens) in zip(unique, results) {
                    map[content] = tokens
                }
                return .lineMap(map)
            })
    }
}
