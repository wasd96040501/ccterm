import Foundation

/// What a session tab is called (design 08 *Tabs and the +*): *New Session*
/// while it is a draft; once its first prompt is sent, that prompt's first
/// line cut at 40 characters; and when the CLI names the session
/// (`session_title_changed`) the CLI's name. A session read from disk keeps
/// the title the sidebar gave it. Pure.
nonisolated enum SessionTabTitle {
    /// The longest a prompt's line is in a tab.
    static let promptLength = 40

    /// What a New tab is called.
    static var draft: String { String(localized: "New Session") }

    /// `prompt`'s first non-empty line, cut at `promptLength` characters
    /// (marked with an ellipsis); *New Session* for words with no line in them.
    static func fromPrompt(_ prompt: String) -> String {
        let line =
            prompt.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let line else { return draft }
        guard line.count > promptLength else { return line }
        return String(line.prefix(promptLength)) + "…"
    }

    /// The title to show: the CLI's name for the session when it has one, else
    /// the first prompt's line, else `fallback` (the sidebar's, for a session
    /// opened from disk).
    static func resolved(cli: String?, prompt: String?, fallback: String) -> String {
        if let cli, !cli.isEmpty { return cli }
        if let prompt { return fromPrompt(prompt) }
        return fallback
    }
}
