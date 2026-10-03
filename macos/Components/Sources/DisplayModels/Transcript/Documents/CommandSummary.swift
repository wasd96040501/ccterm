import Foundation

/// What a command document says, worded (02-command.md): what was meant, what
/// ran, the status line's facts, and what came out. The app words one from a
/// call or a `!` command (`CommandSummary+Call`); the command view draws it.
public nonisolated struct CommandSummary: Sendable, Equatable {
    /// What was meant: the description, *Command* without one, *You ran* for
    /// a `!` command.
    public var heading: String
    /// Only facts that are true: *Failed · exit 65 · 48s*.
    public var status: StyledText
    /// The one warning the page has: *Sandbox off*.
    public var warning: String?
    /// What ran, whole.
    public var command: String
    /// The CLI's note on a meaningful exit code, above the output.
    public var note: String?
    /// What stands where the output would be when there is none.
    public var emptyNote: String?
    /// The call is going, so `emptyNote` is drawn with the running tile.
    public var isRunning = false
    /// What the command printed: the CLI runs it with stderr into stdout, so
    /// this is both streams, in the order they were printed.
    public var stdout = ""
    /// Whatever else the CLI recorded as stderr — not its own note.
    public var stderr = ""
    /// Where the CLI put the whole output when it was too long to keep.
    public var persistedPath: String?
    /// The sentence that leads to `persistedPath`, which follows it.
    public var persistedNote: String?
    /// Whether the document has an output area at all: a command that is
    /// waiting, denied or still preparing has none.
    public var hasOutputArea = true

    public init(
        heading: String = "", status: StyledText = StyledText(), warning: String? = nil, command: String = "",
        note: String? = nil, emptyNote: String? = nil, isRunning: Bool = false, stdout: String = "",
        stderr: String = "", persistedPath: String? = nil, persistedNote: String? = nil, hasOutputArea: Bool = true
    ) {
        self.heading = heading
        self.status = status
        self.warning = warning
        self.command = command
        self.note = note
        self.emptyNote = emptyNote
        self.isRunning = isRunning
        self.stdout = stdout
        self.stderr = stderr
        self.persistedPath = persistedPath
        self.persistedNote = persistedNote
        self.hasOutputArea = hasOutputArea
    }

    // MARK: - Reading

    /// Whether a line of stdout is one that says what went wrong; its number
    /// turns red. Every line of stderr does.
    public static func isErrorLine(_ line: String) -> Bool {
        line.contains("error:") || line.contains("fatal:") || line.contains("FAILED")
            || line.range(of: #"Error \d"#, options: .regularExpression) != nil
    }
}
