import Foundation

/// What General sets about how the CLI is started: the launch command and the
/// folder the CLI keeps its configuration and sessions in. Empty means the
/// default — the `claude` found on this Mac, its own folder.
nonisolated struct LaunchPreferences: Equatable, Sendable {
    /// The command that replaces `claude`; empty runs `claude`.
    var command = ""
    /// `CLAUDE_CONFIG_DIR`; empty leaves the CLI's default (`~/.claude`).
    var configDirectory = ""
    /// Whether every launch carries `--allow-dangerously-skip-permissions`, the
    /// only way a session can enter Bypass Permissions later (General's *Allow
    /// Bypass Permissions*, off by default).
    var allowsBypassPermissions = false

    /// What is wrong with `path` as the configuration folder, ready to show;
    /// `nil` when it is empty (the default) or an existing folder. A leading
    /// `~` is the home directory.
    static func folderProblem(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: (trimmed as NSString).expandingTildeInPath, isDirectory: &isDirectory)
        guard exists else { return String(localized: "Folder doesn’t exist") }
        return isDirectory.boolValue ? nil : String(localized: "Not a folder")
    }
}
