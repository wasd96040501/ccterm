import AppKit

/// Highlight planning for `ReadChild` — mirrors `FileEditChildHighlight`.
/// The body is rendered through `DiffLayout` in new-file mode, which
/// looks tokens up per raw line, so we send the same per-unique-line
/// batch: every distinct line in the file becomes one request and the
/// returned tokens are folded back into a `.lineMap` keyed by content.
///
/// Returns `nil` when the file hasn't loaded yet (`content == nil`) or
/// when the only non-empty lines are duplicates that resolved to zero
/// entries — the storage skips empty plans without enlarging the JS
/// batch.
enum ReadChildHighlight {
    static func plan(_ child: ReadChild) -> ToolGroupChildHighlight.Plan? {
        guard let content = child.content, !content.isEmpty else { return nil }
        let lang = LanguageDetection.language(for: child.filePath)
        var seen = Set<String>()
        var unique: [String] = []
        for line in content.split(separator: "\n", omittingEmptySubsequences: false)
        where !line.isEmpty {
            let s = String(line)
            if seen.insert(s).inserted { unique.append(s) }
        }
        guard !unique.isEmpty else { return nil }
        return ToolGroupChildHighlight.Plan(
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
