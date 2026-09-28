import Foundation

/// Locates a session's history JSONL. All `nonisolated static` — no actor
/// isolation, no handle state. Reading it is `AgentSDK.Transcript`'s job (see
/// `TranscriptPageSource`).
enum HistoryLoader {

    // MARK: - Path resolution

    /// Claude CLI's live JSONL directory
    /// (`~/.claude/projects/<slug>/<sessionId>.jsonl`).
    nonisolated static var claudeProjectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    /// History JSONL URL for `sessionId`. Resolution order:
    /// 1. CLI's live file at
    ///    `~/.claude/projects/<slug>/<sessionId>.jsonl`. `slug` comes
    ///    from `SessionRecord.slug` and is intended to match Claude
    ///    CLI's `sanitizePath`.
    /// 2. Fallback scan of `~/.claude/projects/*/<sessionId>.jsonl`. The
    ///    CLI's on-disk layout is **exactly one level deep**, so this
    ///    is a single shallow loop — cheap. Catches any case where (1)
    ///    misses (slug drift, canonicalize/realpath divergence, or a
    ///    worktree JSONL the CLI wrote under a different slug than our
    ///    record persisted).
    nonisolated static func locate(sessionId: String, slug: String?) -> URL? {
        locate(
            sessionId: sessionId,
            slug: slug,
            projectsRoot: claudeProjectsRoot)
    }

    /// Root-injected overload. Tests point `projectsRoot` at a tmpdir so
    /// the same resolution order can be exercised without touching
    /// `~/.claude/projects`.
    nonisolated static func locate(
        sessionId: String,
        slug: String?,
        projectsRoot: URL
    ) -> URL? {
        if let slug {
            let live =
                projectsRoot
                .appendingPathComponent(slug)
                .appendingPathComponent("\(sessionId).jsonl")
            if FileManager.default.fileExists(atPath: live.path) { return live }
        }

        return scanForSession(sessionId, under: projectsRoot)
    }

    /// Scan `~/.claude/projects/*/<sessionId>.jsonl`. Returns the first
    /// hit. Used as a slug-mismatch safety net by `locate(sessionId:slug:)`.
    nonisolated static func scanProjectsForSession(_ sessionId: String) -> URL? {
        scanForSession(sessionId, under: claudeProjectsRoot)
    }

    /// Underlying scanner taking an explicit root, exposed so tests can
    /// point it at a tmpdir instead of `~/.claude/projects/`. The CLI's
    /// on-disk layout is exactly one level deep (a flat list of slug
    /// directories, each containing JSONLs), so this is a single
    /// shallow loop — no recursion required, no JSONL bytes read.
    nonisolated static func scanForSession(_ sessionId: String, under root: URL) -> URL? {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { return nil }
        for entry in entries {
            let isDir =
                (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            let candidate = entry.appendingPathComponent("\(sessionId).jsonl")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
