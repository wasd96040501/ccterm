import Foundation

/// Unified-diff payload. Hunks are derived inside `DiffLayout.make` from
/// `oldString`/`newString` via the shared `DiffEngine`, so the Block stays
/// a thin "what to render" record: storing pre-computed hunks here would
/// duplicate state with the layout cache and force the caller to re-run
/// the diff engine before every update.
///
/// `oldString == nil` is the "new file" signal — the file didn't exist
/// before this edit. The renderer suppresses the green `+` insertion
/// styling (no sign column glyph, no add-tinted line/gutter bg) so the
/// body reads as "code with a gutter" rather than "a diff that's all
/// additions." Line numbers and async syntax highlighting are kept, so
/// the result is a viewable copy of the new file's contents without
/// diff chrome noise. Matches the `suppressInsertionStyle` flag in the
/// older `NativeDiffView`. Callers map a nullable `originalContent` field
/// (e.g. tool-result payload) straight into `oldString` without a
/// `?? ""` coalesce.
struct DiffBlock: Equatable, Sendable {
    let filePath: String
    let oldString: String?
    let newString: String

    /// True when no prior content exists — drives the "suppress
    /// insertion styling" branch inside `DiffLayout`.
    var isNewFile: Bool { oldString == nil }

    /// Sanitised `old` for `DiffEngine` consumers. Diff against an empty
    /// string when the prior file didn't exist; the renderer
    /// downstream then chooses how to style those rows.
    var effectiveOldString: String { oldString ?? "" }

    /// Iteration helper used by `Transcript2HighlightStorage.plan(for:)`
    /// to enumerate the set of distinct line strings the diff will
    /// surface — the highlight payload is keyed by raw line content.
    /// Re-runs `DiffEngine.computeHunks` (cheap on short inputs;
    /// `DiffLayout.make` runs it again and caches its hunks per-layout).
    var lines: [String] {
        DiffEngine.computeHunks(old: effectiveOldString, new: newString)
            .flatMap { $0.lines.map(\.content) }
    }
}
