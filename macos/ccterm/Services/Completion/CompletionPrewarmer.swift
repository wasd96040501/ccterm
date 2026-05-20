import Foundation

/// Single async-prewarm entry point for the completion popup.
///
/// `prewarm(...)` is the only function call sites need to know about —
/// it fans out into the per-source background loads (file index +
/// slash command list) so the popup is hot the first time the user
/// types `@` or `/`. Trigger sources converge into one call site
/// (`InputBarChrome.task(id: CompletionPrewarmer.Key)`), keeping the
/// "what gets warmed" logic in one place rather than scattered across
/// the view layer.
///
/// Idempotent and cheap to call on every config change; both stores
/// dedupe internally on a per-directory cache. Safe to call with
/// `directory == nil` — that's the compose-mode-before-folder-pick
/// case, and the function early-returns.
enum CompletionPrewarmer {
    /// Joined cache key. Stable & `Equatable` so SwiftUI's `.task(id:)`
    /// only re-fires the prewarm when something the popup actually
    /// uses (cwd, extra dirs, plugin dirs) changes.
    struct Key: Equatable {
        let directory: String?
        let additionalDirs: [String]
        let pluginDirs: [String]
    }

    static func prewarm(_ key: Key) {
        guard let dir = key.directory, !dir.isEmpty else { return }
        var fileDirs = [dir]
        fileDirs.append(contentsOf: key.additionalDirs)
        FileCompletionStore.shared.warm(directories: fileDirs)
        SlashCommandStore.shared.warm(path: dir, pluginDirs: key.pluginDirs)
    }
}
