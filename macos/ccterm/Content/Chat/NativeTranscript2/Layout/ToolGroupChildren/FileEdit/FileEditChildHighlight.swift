import AppKit

/// Highlight planning for `FileEditChild` — per-unique-line tokenisation.
/// Each non-empty line in the diff is sent as its own request; tokens
/// come back keyed by raw line content, which the draw pass can look up
/// regardless of which hunk the line lives in.
///
/// Same simplification as the old `NativeDiffView` made for the same
/// reason: cross-line context is lost, but caching by content lets us
/// dedupe duplicate lines (very common in real diffs).
enum FileEditChildHighlight {
    static func plan(_ child: FileEditChild) -> ToolGroupChildHighlight.Plan? {
        let lang = LanguageDetection.language(for: child.filePath)
        var seen = Set<String>()
        var unique: [String] = []
        for line in child.diff.lines where !line.isEmpty {
            if seen.insert(line).inserted { unique.append(line) }
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
