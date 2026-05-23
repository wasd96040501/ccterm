import Foundation
import Observation

/// User-defaults-backed list of recently picked project folders shown in
/// the New Session compose card. Independent of `SessionManager.records`
/// (the Core Data session list) — recents are a lightweight UI affordance,
/// not a record of session history, so they live in a place that's cheap
/// to read, cheap to write, and cheap to wipe.
///
/// Rules:
///
/// - Entries are unique by absolute path.
/// - Newest first; `add(_:)` moves an existing path to the front and bumps
///   its `lastUsed`.
/// - Missing folders are pruned silently — both in memory AND in
///   UserDefaults — every time the store loads. Same goes for the
///   `lastLaunchedPath` and worktree-pref slices.
/// - **Load is lazy.** `init` does no I/O. The first time any public
///   member is read, the store decodes UserDefaults, walks every
///   persisted path with `FileManager.fileExists`, and writes the
///   pruned shape back. The fileExists pass is what triggers macOS's
///   TCC "external volume" prompt when a recent lives on `/Volumes/...`
///   — eager-loading from `AppState.init` made that prompt fire on
///   every app launch (and every XCTest fork, since the host app
///   constructs `AppState` even under XCTest). Deferring to first
///   read scopes the prompt to "user just opened the New Session
///   card and is about to need this data."
@Observable
@MainActor
final class RecentProjectsStore {

    private static let defaultsKey = "RecentProjects.v1"
    /// UserDefaults key for the *last successfully launched* project path.
    /// Distinct from `entries`: a folder can be added to recents by just
    /// browsing in the picker, but only counts as "launched" once the user
    /// submits the first message in that draft. Used to pre-fill the next
    /// New Session card.
    private static let lastLaunchedKey = "RecentProjects.lastLaunched.v1"
    /// UserDefaults key for the per-project worktree preference. Stored as
    /// a JSON-encoded `[String: Bool]` keyed by absolute project path. Only
    /// written on launch (so toggling without sending doesn't poison the
    /// next visit), read back when the compose card pre-fills for a folder.
    private static let worktreePrefsKey = "RecentProjects.worktreePrefs.v1"

    struct Entry: Codable, Hashable, Identifiable {
        let path: String
        var lastUsed: Date

        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
    }

    // Backing storage; public surface is computed and routes through
    // `loadIfNeeded()`. Keep these as plain stored properties (no
    // `@ObservationIgnored`) so SwiftUI views that read `entries` /
    // `lastLaunchedPath` still get a re-render when the deferred load
    // populates them.
    private var _entries: [Entry] = []
    private var _lastLaunchedPath: String?
    @ObservationIgnored private var worktreePrefs: [String: Bool] = [:]
    @ObservationIgnored private var hasLoaded = false

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// macOS 26 SDK workaround — see `Session.deinit` for the
    /// background. The default `@MainActor` deinit routes through
    /// `swift_task_deinitOnExecutorImpl` and traps; `nonisolated`
    /// skips that path. The host-aware reentry test deallocates this
    /// store on test teardown, which is when the trap fires.
    nonisolated deinit {}

    var entries: [Entry] {
        loadIfNeeded()
        return _entries
    }

    /// Path of the most recent project the user actually launched a session
    /// from (by clicking send on a fresh draft). Survives across app
    /// launches via UserDefaults; nil if no launch has happened yet or the
    /// stored path no longer exists on disk.
    var lastLaunchedPath: String? {
        loadIfNeeded()
        return _lastLaunchedPath
    }

    /// Insert or refresh `path` at the front of the list.
    func add(_ path: String) {
        loadIfNeeded()
        var next = _entries.filter { $0.path != path }
        next.insert(Entry(path: path, lastUsed: Date()), at: 0)
        _entries = next
        saveEntries()
    }

    /// Record `path` as the last project that successfully launched a
    /// session. Also bumps it to the front of the recents list (a launched
    /// project is by definition a recent one), and persists the user's
    /// worktree choice for that path so the next compose-card visit
    /// pre-fills it.
    func markLaunched(_ path: String, useWorktree: Bool) {
        loadIfNeeded()
        var next = _entries.filter { $0.path != path }
        next.insert(Entry(path: path, lastUsed: Date()), at: 0)
        _entries = next
        saveEntries()
        _lastLaunchedPath = path
        defaults.set(path, forKey: Self.lastLaunchedKey)
        worktreePrefs[path] = useWorktree
        saveWorktreePrefs()
    }

    /// Look up the saved worktree preference for `path`. Returns `nil` when
    /// the project has never been launched (caller decides the default).
    func useWorktree(for path: String) -> Bool? {
        loadIfNeeded()
        return worktreePrefs[path]
    }

    /// Remove `path` from the list. No-op if absent.
    func remove(_ path: String) {
        loadIfNeeded()
        let next = _entries.filter { $0.path != path }
        guard next.count != _entries.count else { return }
        _entries = next
        saveEntries()
        if _lastLaunchedPath == path {
            _lastLaunchedPath = nil
            defaults.removeObject(forKey: Self.lastLaunchedKey)
        }
        if worktreePrefs.removeValue(forKey: path) != nil {
            saveWorktreePrefs()
        }
    }

    /// Drop entries whose folder no longer exists on disk. Cheap enough
    /// to call on every UI read.
    func prune() {
        loadIfNeeded()
        let fm = FileManager.default
        let surviving = _entries.filter { fm.fileExists(atPath: $0.path) }
        guard surviving.count != _entries.count else { return }
        _entries = surviving
        saveEntries()
    }

    /// One-shot deferred load. Reads all three UserDefaults slices and
    /// prunes any path whose folder no longer exists, writing the pruned
    /// shape back so the bad entries don't resurface on the next launch.
    /// Idempotent — `hasLoaded` guards re-entry on every subsequent
    /// public-member read.
    private func loadIfNeeded() {
        if hasLoaded { return }
        hasLoaded = true
        loadEntries()
        loadLastLaunched()
        loadWorktreePrefs()
    }

    private func loadEntries() {
        guard
            let data = defaults.data(forKey: Self.defaultsKey),
            let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else {
            _entries = []
            return
        }
        let fm = FileManager.default
        let surviving = decoded.filter { fm.fileExists(atPath: $0.path) }
        _entries = surviving.sorted { $0.lastUsed > $1.lastUsed }
        if surviving.count != decoded.count { saveEntries() }
    }

    private func saveEntries() {
        guard let data = try? JSONEncoder().encode(_entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private func loadLastLaunched() {
        guard let stored = defaults.string(forKey: Self.lastLaunchedKey) else {
            _lastLaunchedPath = nil
            return
        }
        if FileManager.default.fileExists(atPath: stored) {
            _lastLaunchedPath = stored
        } else {
            _lastLaunchedPath = nil
            defaults.removeObject(forKey: Self.lastLaunchedKey)
        }
    }

    private func loadWorktreePrefs() {
        guard
            let data = defaults.data(forKey: Self.worktreePrefsKey),
            let decoded = try? JSONDecoder().decode([String: Bool].self, from: data)
        else {
            worktreePrefs = [:]
            return
        }
        let fm = FileManager.default
        let surviving = decoded.filter { fm.fileExists(atPath: $0.key) }
        worktreePrefs = surviving
        if surviving.count != decoded.count { saveWorktreePrefs() }
    }

    private func saveWorktreePrefs() {
        guard let data = try? JSONEncoder().encode(worktreePrefs) else { return }
        defaults.set(data, forKey: Self.worktreePrefsKey)
    }
}
