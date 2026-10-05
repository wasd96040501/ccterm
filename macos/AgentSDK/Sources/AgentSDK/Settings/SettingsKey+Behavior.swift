import Foundation

// Conversation, context and tool behavior.

extension SettingsKey where Value == String {
    /// The output style for responses, by name
    /// (``InitializationResult/availableOutputStyles`` lists them).
    public static var outputStyle: Self { Self("outputStyle") }

    /// The language Claude answers in (`japanese`, `spanish`, …).
    public static var language: Self { Self("language") }

    /// Where plan files go, relative to the project root.
    public static var plansDirectory: Self { Self("plansDirectory") }
}

extension SettingsKey where Value == [String: String] {
    /// Environment variables for the session's tools and hooks.
    public static var env: Self { Self("env") }
}

extension SettingsKey where Value == AttributionSettings {
    /// Attribution text for commits and pull requests.
    public static var attribution: Self { Self("attribution") }
}

extension SettingsKey where Value == Bool {
    /// Whether the system prompt carries the built-in commit and PR workflow
    /// instructions. Default `true`.
    public static var includeGitInstructions: Self { Self("includeGitInstructions") }

    /// Whether the conversation compacts itself when the context fills.
    public static var autoCompactEnabled: Self { Self("autoCompactEnabled") }

    /// Whether Claude reads and writes the project's auto-memory.
    public static var autoMemoryEnabled: Self { Self("autoMemoryEnabled") }

    /// Whether files are snapshotted before edits so a rewind can restore them.
    public static var fileCheckpointingEnabled: Self { Self("fileCheckpointingEnabled") }

    /// Whether the session suggests a next prompt after each turn.
    public static var promptSuggestionEnabled: Self { Self("promptSuggestionEnabled") }

    /// Whether the todo / task tracking panel is on.
    public static var todoFeatureEnabled: Self { Self("todoFeatureEnabled") }

    /// Whether the `@` file picker skips `.gitignore`d files. Default `true`.
    public static var respectGitignore: Self { Self("respectGitignore") }
}

extension SettingsKey where Value == Int {
    /// Characters of a successful shell command's output Claude receives
    /// inline (clamped to 4 000–128 000); the rest is saved to a file.
    public static var bashOutputMaxChars: Self { Self("bashOutputMaxChars") }

    /// Days transcripts are kept before cleanup; at least 1.
    public static var cleanupPeriodDays: Self { Self("cleanupPeriodDays") }
}

extension SettingsKey where Value == JSONValue {
    /// How `--worktree` makes its worktree: `{"baseRef": "head"}` branches from
    /// the local HEAD, `"fresh"` (the default) from origin's default branch.
    /// Read at launch (`--settings`). Also holds `symlinkDirectories`, `sparsePaths`
    /// and `bgIsolation`; an applied object replaces the whole value, so a host that
    /// reads the layer first keeps them.
    public static var worktree: Self { Self("worktree") }
}
