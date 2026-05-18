import AgentSDK
import Foundation

/// Pure I/O for a session's history JSONL: locate the file, parse a
/// tail / prefix byte range, decode JSON lines into `Message2`. All
/// `nonisolated static` — no actor isolation, no handle state.
///
/// Split out of `Session+History.swift` so the file-system and
/// parsing paths can be exercised in isolation. The two-phase
/// orchestration (`loadHistory()`) that consumes these results still
/// lives on `Session` because it's tightly coupled to handle
/// state (`messages`, `historyLoadState`, `onMessagesChange`).
enum HistoryLoader {

    // MARK: - Path resolution

    /// Claude CLI's live JSONL directory
    /// (`~/.claude/projects/<slug>/<sessionId>.jsonl`).
    nonisolated static var claudeProjectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    /// CCTerm's own export JSONL directory (contains the full stdio
    /// stream). Preferred over the live file because it captures every
    /// byte the SDK forwarded.
    nonisolated static var exportRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/ccterm/export")
    }

    /// History JSONL URL for `sessionId`. Resolution order:
    /// 1. ccterm's own export at
    ///    `~/.cache/ccterm/export/<sessionId>.jsonl`.
    /// 2. CLI's live file at
    ///    `~/.claude/projects/<slug>/<sessionId>.jsonl`. `slug` comes
    ///    from `SessionRecord.slug` and is intended to match Claude
    ///    CLI's `sanitizePath`.
    /// 3. Fallback scan of `~/.claude/projects/*/<sessionId>.jsonl`. The
    ///    CLI's on-disk layout is **exactly one level deep**, so this
    ///    is a single shallow loop — cheap. Catches any case where (2)
    ///    misses (slug drift, canonicalize/realpath divergence, or a
    ///    worktree JSONL the CLI wrote under a different slug than our
    ///    record persisted).
    nonisolated static func locate(sessionId: String, slug: String?) -> URL? {
        locate(
            sessionId: sessionId,
            slug: slug,
            exportRoot: exportRoot,
            projectsRoot: claudeProjectsRoot)
    }

    /// Root-injected overload. Tests point `exportRoot` / `projectsRoot`
    /// at a tmpdir so the same resolution order can be exercised
    /// without touching `~/.cache/ccterm` or `~/.claude/projects`.
    nonisolated static func locate(
        sessionId: String,
        slug: String?,
        exportRoot: URL,
        projectsRoot: URL
    ) -> URL? {
        let export = exportRoot.appendingPathComponent("\(sessionId).jsonl")
        if FileManager.default.fileExists(atPath: export.path) { return export }

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

    // MARK: - Parsers

    /// Result of `parseTail`. `tailStartByteOffset` is the byte offset
    /// where the tail begins inside the file; Phase B reads `[0,
    /// tailStartByteOffset)` to recover the prefix.
    struct TailParsed {
        let messages: [Message2]
        let tailStartByteOffset: Int
    }

    /// Phase A: byte tail + forward parse + per-file `Message2Resolver`.
    /// nil url or missing file → success with empty messages and 0
    /// offset (no history available to render).
    nonisolated static func parseTail(
        at url: URL?, targetLines: Int
    ) -> Result<TailParsed, Error> {
        guard let url else {
            return .success(TailParsed(messages: [], tailStartByteOffset: 0))
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            return .success(TailParsed(messages: [], tailStartByteOffset: 0))
        }
        do {
            let readerResult = try JSONLTailReader.readTail(
                url: url, targetLines: targetLines)
            let msgs = parseLines(readerResult.lines)
            return .success(
                TailParsed(
                    messages: msgs,
                    tailStartByteOffset: readerResult.tailStartByteOffset))
        } catch {
            return .failure(error)
        }
    }

    /// Phase B: read `[0, byteLimit)` and parse into a prefix `[Message2]`,
    /// using its own resolver. The caller backfills any tail
    /// `tool_result`s whose anchor lives in this prefix.
    nonisolated static func parsePrefix(
        at url: URL, byteLimit: Int
    ) -> Result<[Message2], Error> {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: 0)
            let data = try handle.read(upToCount: byteLimit) ?? Data()
            guard let text = String(data: data, encoding: .utf8) else {
                return .failure(ParseError.invalidUTF8)
            }
            let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
            return .success(parseLines(lines))
        } catch {
            return .failure(error)
        }
    }

    /// Forward-parse JSONL text lines into `[Message2]`, dropping lines
    /// that fail to parse.
    nonisolated static func parseLines(_ lines: [String]) -> [Message2] {
        let resolver = Message2Resolver()
        var out: [Message2] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            guard let data = line.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let msg = try? resolver.resolve(json)
            else {
                continue
            }
            out.append(msg)
        }
        return out
    }

    /// Errors emitted by the parsers. Wraps `LocalizedError` so the
    /// orchestrator's failure-state copy is user-readable.
    enum ParseError: LocalizedError {
        case invalidUTF8

        var errorDescription: String? {
            switch self {
            case .invalidUTF8: return "History JSONL is not valid UTF-8"
            }
        }
    }
}
