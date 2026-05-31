import Foundation

/// Persisted session lifecycle state (stored in CDSession.status).
enum SessionStatus: String {
    /// Persisted row for a `/new` / `/clear` session the user has never
    /// sent a message to yet. Routes to the draft-landing page, survives
    /// restart, and is hard-deleted (not archived) on dismiss. The first
    /// send flips it to `.pending`. Treated as "fresh" everywhere a launch
    /// mode is decided (`shouldResumeBootstrap` only resumes `.created`).
    case draft
    /// DB row created; CLI has never successfully initialized (cwd unknown).
    case pending
    /// CLI initialized at least once; full metadata is available.
    case created
    /// Soft-deleted (archived).
    case archived
}

struct SessionExtra: Codable {
    var pluginDirs: [String]?
    var permissionMode: String?
    var addDirs: [String]?
    var model: String?
    var effort: String?

    init(
        pluginDirs: [String]? = nil, permissionMode: String? = nil, addDirs: [String]? = nil, model: String? = nil,
        effort: String? = nil
    ) {
        self.pluginDirs = pluginDirs
        self.permissionMode = permissionMode
        self.addDirs = addDirs
        self.model = model
        self.effort = effort
    }
}

/// Data model for the new session system. Independent of the legacy
/// Session struct; used by SessionService / SessionRepository.
struct SessionRecord: Identifiable {

    let id: UUID
    var sessionId: String
    var title: String
    var cwd: String?
    var isWorktree: Bool
    var originPath: String?
    var createdAt: Date
    var lastActiveAt: Date
    var status: SessionStatus
    var archivedAt: Date?
    var extra: SessionExtra
    var error: String?
    var isPinned: Bool
    var pinnedAt: Date?
    var isTempDir: Bool
    var worktreeBranch: String?

    /// Slug is deterministically derived from cwd, not persisted. Must
    /// match Claude CLI's slug generation byte-for-byte or
    /// `historyJSONLURL` can't find the JSONL the CLI wrote.
    var slug: String? {
        guard let cwd else { return nil }
        return Self.sanitizePath(cwd)
    }

    /// 1:1 port of `sanitizePath` in Claude CLI
    /// `src/utils/sessionStoragePortable.ts` (v2.1.88).
    ///
    /// - NFC-normalize the input (mirrors `canonicalizePath`'s
    ///   `.normalize('NFC')` step).
    /// - Walk **UTF-16 code units** (what JS's `/[^a-zA-Z0-9]/g` operates
    ///   on) and pass through `0-9` / `A-Z` / `a-z`; replace everything
    ///   else with `-`. Supplementary-plane scalars (emoji etc.) end up
    ///   as two `-` because their surrogate pair is two code units.
    /// - If the sanitized form is ≤ 200 chars, return it. Otherwise
    ///   truncate to 200 and append `-<djb2hash(name)>` in base 36.
    ///
    /// Concrete consequences worth pinning down:
    /// - Worktree sessions (cwd contains `.claude/worktrees/`) produce
    ///   a **double dash** in place of `.` — `-...-ccterm--claude-...`,
    ///   not `-...-ccterm-.claude-...`. This was the bug that hid
    ///   worktree-session history after app restart.
    /// - Spaces, dots, colons, plus, parens, slashes, CJK, accented
    ///   letters — all fold to `-`. ASCII hyphen passes through (the
    ///   `-` → `-` mapping is a no-op).
    /// - The CLI's `cli.js` ships with a Node shebang
    ///   (`#!/usr/bin/env node`), so its `typeof Bun !== 'undefined'`
    ///   branch is dead at runtime and djb2 is what hits disk. Bun
    ///   builds would emit a different (wyhash) suffix for >200-char
    ///   paths, but typical user cwds never reach that branch.
    static func sanitizePath(_ name: String) -> String {
        let normalized = name.precomposedStringWithCanonicalMapping
        var sanitized = ""
        sanitized.reserveCapacity(normalized.utf16.count)
        for unit in normalized.utf16 {
            if (0x30...0x39).contains(unit)  // 0-9
                || (0x41...0x5A).contains(unit)  // A-Z
                || (0x61...0x7A).contains(unit)  // a-z
            {
                sanitized.append(Character(UnicodeScalar(unit)!))
            } else {
                sanitized.append("-")
            }
        }
        if sanitized.utf16.count <= maxSanitizedLength { return sanitized }
        let head = sanitized.prefix(maxSanitizedLength)
        let suffix = String(djb2HashAbs(normalized), radix: 36)
        return "\(head)-\(suffix)"
    }

    /// Mirrors `MAX_SANITIZED_LENGTH` in the CLI's
    /// `sessionStoragePortable.ts`. Most filesystems cap a single path
    /// component at 255 bytes — 200 leaves room for the hash suffix and
    /// separator.
    static let maxSanitizedLength = 200

    /// djb2 over UTF-16 code units with 32-bit signed wrap-around (the
    /// `|0` in `hash.ts`'s impl). Returned as `Int64` so a hash equal
    /// to `Int32.min` survives `abs` without trapping — JS's
    /// `Math.abs(-2147483648)` returns `2147483648`, which fits in
    /// Int64. The base-36 stringification then matches the CLI byte for
    /// byte.
    private static func djb2HashAbs(_ str: String) -> Int64 {
        var hash: Int32 = 0
        for unit in str.utf16 {
            hash = (hash &<< 5) &- hash &+ Int32(unit)
        }
        return Swift.abs(Int64(hash))
    }

    var folderName: String? {
        guard let cwd else { return nil }
        return (cwd as NSString).lastPathComponent
    }

    var groupingPath: String? {
        originPath ?? cwd
    }

    var groupingFolderName: String? {
        if isTempDir { return "临时会话" }
        guard let path = groupingPath else { return nil }
        return (path as NSString).lastPathComponent
    }

    init(
        id: UUID = UUID(),
        sessionId: String,
        title: String = "[unknown session]",
        cwd: String? = nil,
        isWorktree: Bool = false,
        originPath: String? = nil,
        createdAt: Date = Date(),
        lastActiveAt: Date = Date(),
        status: SessionStatus = .pending,
        archivedAt: Date? = nil,
        extra: SessionExtra = SessionExtra(),
        error: String? = nil,
        isPinned: Bool = false,
        pinnedAt: Date? = nil,
        isTempDir: Bool = false,
        worktreeBranch: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.title = title
        self.cwd = cwd
        self.isWorktree = isWorktree
        self.originPath = originPath
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
        self.status = status
        self.archivedAt = archivedAt
        self.extra = extra
        self.error = error
        self.isPinned = isPinned
        self.pinnedAt = pinnedAt
        self.isTempDir = isTempDir
        self.worktreeBranch = worktreeBranch
    }
}
