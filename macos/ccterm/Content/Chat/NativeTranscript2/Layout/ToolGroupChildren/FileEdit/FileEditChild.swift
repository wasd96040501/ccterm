import Foundation

/// `fileEdit` child payload — a single file's diff.
///
/// `label` is the human-facing header text (e.g.
/// `"Edit Sources/Greeter.swift"` or the past-tense
/// `"Edited Sources/Greeter.swift"`); the renderer shows it verbatim
/// without injecting any extra prefix. Mirrors the old
/// `ReadChildRenderer`, which pulled `tool.completedFragment`
/// (past-tense by default — the active phrase belongs to the group
/// header that wraps these children).
///
/// `filePath` is kept separate from `label` because it has a non-text
/// job: it feeds `LanguageDetection` for syntax highlighting and
/// would be unreliable to recover from the localized label string.
struct FileEditChild: Equatable, Sendable {
    /// Stable identity for fold-state and highlight keys.
    let id: UUID
    /// Header text displayed in the child header row.
    let label: String
    /// Path used for syntax-highlight language detection (independent
    /// of the displayed `label`).
    let filePath: String
    let diff: DiffBlock
}
