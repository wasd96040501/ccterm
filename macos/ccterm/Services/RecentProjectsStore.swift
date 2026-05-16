import Foundation
import Observation

/// User-defaults-backed list of recently picked project folders shown in
/// the New Session compose card. Independent of `SessionManager2.records`
/// (the Core Data session list) — recents are a lightweight UI affordance,
/// not a record of session history, so they live in a place that's cheap
/// to read, cheap to write, and cheap to wipe.
///
/// Rules:
///
/// - Entries are unique by absolute path.
/// - Newest first; `add(_:)` moves an existing path to the front and bumps
///   its `lastUsed`.
/// - Missing folders are pruned silently. The store calls `prune()` on
///   load and exposes the same method for callers that want to clean up
///   on user-visible interactions (e.g. just before showing the list).
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

    struct Entry: Codable, Hashable, Identifiable {
        let path: String
        var lastUsed: Date

        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
    }

    private(set) var entries: [Entry] = []
    /// Path of the most recent project the user actually launched a session
    /// from (by clicking send on a fresh draft). Survives across app
    /// launches via UserDefaults; nil if no launch has happened yet or the
    /// stored path no longer exists on disk.
    private(set) var lastLaunchedPath: String?

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
        loadLastLaunched()
    }

    /// Insert or refresh `path` at the front of the list.
    func add(_ path: String) {
        var next = entries.filter { $0.path != path }
        next.insert(Entry(path: path, lastUsed: Date()), at: 0)
        entries = next
        save()
    }

    /// Record `path` as the last project that successfully launched a
    /// session. Also bumps it to the front of the recents list (a launched
    /// project is by definition a recent one).
    func markLaunched(_ path: String) {
        add(path)
        lastLaunchedPath = path
        defaults.set(path, forKey: Self.lastLaunchedKey)
    }

    /// Remove `path` from the list. No-op if absent.
    func remove(_ path: String) {
        let next = entries.filter { $0.path != path }
        guard next.count != entries.count else { return }
        entries = next
        save()
        if lastLaunchedPath == path {
            lastLaunchedPath = nil
            defaults.removeObject(forKey: Self.lastLaunchedKey)
        }
    }

    /// Drop entries whose folder no longer exists on disk. Cheap enough
    /// to call on every UI read.
    func prune() {
        let fm = FileManager.default
        let surviving = entries.filter { fm.fileExists(atPath: $0.path) }
        guard surviving.count != entries.count else { return }
        entries = surviving
        save()
    }

    private func load() {
        guard
            let data = defaults.data(forKey: Self.defaultsKey),
            let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else {
            entries = []
            return
        }
        let fm = FileManager.default
        let surviving = decoded.filter { fm.fileExists(atPath: $0.path) }
        entries = surviving.sorted { $0.lastUsed > $1.lastUsed }
        if surviving.count != decoded.count { save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private func loadLastLaunched() {
        guard let stored = defaults.string(forKey: Self.lastLaunchedKey) else {
            lastLaunchedPath = nil
            return
        }
        if FileManager.default.fileExists(atPath: stored) {
            lastLaunchedPath = stored
        } else {
            lastLaunchedPath = nil
            defaults.removeObject(forKey: Self.lastLaunchedKey)
        }
    }
}
