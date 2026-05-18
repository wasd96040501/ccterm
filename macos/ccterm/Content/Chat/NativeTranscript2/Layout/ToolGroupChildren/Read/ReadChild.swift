import Foundation

/// `read` child payload — file-read tool.
///
/// `label` is the human-facing header text (e.g. `"Read Sources/Greeter.swift"`,
/// past-tense by default — the active phrasing belongs to the group
/// header that wraps these children).
///
/// `filePath` is kept separate from `label` so the language detector
/// (used by syntax highlighting) doesn't have to parse the localized
/// label.
///
/// `content` is the file body the CLI returned in the tool_result. It
/// arrives as `<lineNo>\t<text>` lines (`cat -n` style) and the bridge
/// strips the line-number prefix before stashing it here, so the
/// renderer just hands the raw text to `DiffLayout` in new-file mode.
/// `nil` until the tool_result lands.
struct ReadChild: Equatable, Sendable {
    let id: UUID
    /// Past-tense / completed-form header text (e.g.
    /// `"Read Sources/Greeter.swift"`). Routed via
    /// `Child.headerLabel(for:)` for any non-`.running` status.
    let label: String
    /// Progressive / running-form header text (e.g.
    /// `"Reading Sources/Greeter.swift"`). Used when the child's
    /// `ToolStatus` is `.running`.
    let activeLabel: String
    let filePath: String
    /// File body returned by the tool result, with `cat -n` line-number
    /// prefixes stripped. `nil` while the tool is still running (no
    /// result yet) or when the result didn't carry any text content.
    /// When non-nil, `ReadChildLayout` renders the body as a new-file
    /// diff card so the contents read as line-numbered code.
    let content: String?
}
