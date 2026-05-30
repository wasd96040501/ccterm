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
    /// Past-tense / completed-form header text (e.g.
    /// `"Edit Sources/Greeter.swift"`). Used for any non-`.running`
    /// status. Routed via `Child.headerLabel(for:)`.
    let label: String
    /// Progressive / running-form header text (e.g.
    /// `"Editing Sources/Greeter.swift"`). Used when the child's
    /// `ToolStatus` is `.running`. Bridge fills this from
    /// `ToolUse.activeFragment`.
    let activeLabel: String
    /// Path used for syntax-highlight language detection (independent
    /// of the displayed `label`).
    let filePath: String
    let diff: DiffBlock
    /// Wrapper-level error text (`tool_result.is_error == true`), stripped
    /// of the `<tool_use_error>` envelope. `nil` on success. Rendered as a
    /// uniform red error card below the diff body by `ToolGroupChildLayout`.
    var errorText: String? = nil
}
