import Foundation

/// Something the reader did to the CLI rather than said to the model: a
/// slash command or a `!` shell command, with what it printed
/// (design/transcript/05-local.md). Drawn as a capsule on the reader's side.
///
/// `/compact` and `/exit` never become one: they fold into the
/// `SessionDivider` they mark.
nonisolated struct LocalCommand: Sendable, Equatable, Identifiable {
    let id: String
    let command: Command
    /// What it printed on standard output — empty while it has printed
    /// nothing, or when it never does.
    var output: String
    var errorOutput: String

    enum Command: Sendable, Equatable {
        /// `/model` with arguments `opus`. The name keeps its slash.
        case slash(name: String, arguments: String)
        /// A `!` command, without the `!`.
        case shell(String)
    }
}
