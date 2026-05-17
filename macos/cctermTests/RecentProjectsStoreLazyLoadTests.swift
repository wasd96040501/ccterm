import XCTest

@testable import ccterm

/// Pins the lazy-load contract on `RecentProjectsStore`:
///
/// 1. `init` performs no I/O — UserDefaults is not read, filesystem is
///    not probed. This matters because the on-disk prune calls
///    `FileManager.fileExists` on every persisted path; when a recent
///    sits on `/Volumes/<external>` it triggers macOS's TCC
///    "removable / external volume" prompt. Eager load on the
///    `AppState` path fired that prompt on every app launch *and* on
///    every XCTest fork (the host app still constructs `AppState`
///    under XCTest).
/// 2. The first read of any public member triggers the load and
///    prunes any path whose folder doesn't exist on disk, writing the
///    pruned shape back to UserDefaults so the bad entries don't
///    resurface.
///
/// We use a per-test `UserDefaults` suite (named with a UUID) so the
/// developer's real defaults are never touched and tests can run in
/// parallel.
@MainActor
final class RecentProjectsStoreLazyLoadTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        continueAfterFailure = false
        suiteName = "ccterm.recents-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        XCTAssertNotNil(defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - init does no I/O

    func testInitDoesNotReadDefaults() throws {
        // Pre-seed defaults with a path that does NOT exist on disk. If
        // `init` eagerly loaded, it would `fileExists` the path, fail,
        // and rewrite the key with an empty list.
        let bogus = "/var/empty/ccterm-does-not-exist-\(UUID().uuidString)"
        try seedEntries([entry(path: bogus)])
        try seedLastLaunched(bogus)
        try seedWorktreePrefs([bogus: true])

        let store = RecentProjectsStore(defaults: defaults)
        _ = store  // suppress unused-warning

        // All three keys must remain exactly as seeded — the store
        // hasn't touched them.
        let entriesData = defaults.data(forKey: "RecentProjects.v1")
        XCTAssertNotNil(entriesData)
        let decoded = try JSONDecoder().decode(
            [RecentProjectsStore.Entry].self, from: XCTUnwrap(entriesData))
        XCTAssertEqual(decoded.count, 1, "init must not have rewritten the entries array")
        XCTAssertEqual(decoded.first?.path, bogus)

        XCTAssertEqual(
            defaults.string(forKey: "RecentProjects.lastLaunched.v1"), bogus,
            "init must not have cleared the lastLaunched path")
        XCTAssertNotNil(
            defaults.data(forKey: "RecentProjects.worktreePrefs.v1"),
            "init must not have rewritten worktreePrefs")
    }

    // MARK: - first read triggers prune-and-write-back

    func testFirstEntriesReadPrunesNonexistentPathsFromDefaults() throws {
        // Mix: one path that exists (the per-test temp dir) + one that
        // doesn't.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-recents-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmpDir) }

        let bogus = "/var/empty/ccterm-does-not-exist-\(UUID().uuidString)"
        try seedEntries([
            entry(path: tmpDir.path, lastUsed: Date()),
            entry(path: bogus, lastUsed: Date().addingTimeInterval(-10)),
        ])

        let store = RecentProjectsStore(defaults: defaults)

        // First access — this is what triggers the load + prune + write-back.
        let observed = store.entries

        XCTAssertEqual(observed.map(\.path), [tmpDir.path])

        let persisted = try JSONDecoder().decode(
            [RecentProjectsStore.Entry].self,
            from: XCTUnwrap(defaults.data(forKey: "RecentProjects.v1")))
        XCTAssertEqual(
            persisted.map(\.path), [tmpDir.path],
            "the bogus path must have been removed from UserDefaults, not just from the in-memory list")
    }

    func testFirstLastLaunchedReadDeletesStaleKeyFromDefaults() throws {
        let bogus = "/var/empty/ccterm-does-not-exist-\(UUID().uuidString)"
        try seedLastLaunched(bogus)

        let store = RecentProjectsStore(defaults: defaults)

        XCTAssertNil(store.lastLaunchedPath, "stale path must not be returned")
        XCTAssertNil(
            defaults.string(forKey: "RecentProjects.lastLaunched.v1"),
            "stale key must be removed from UserDefaults")
    }

    func testFirstWorktreePrefReadPrunesNonexistentKeysFromDefaults() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-recents-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmpDir) }

        let bogus = "/var/empty/ccterm-does-not-exist-\(UUID().uuidString)"
        try seedWorktreePrefs([tmpDir.path: true, bogus: false])

        let store = RecentProjectsStore(defaults: defaults)

        XCTAssertEqual(store.useWorktree(for: tmpDir.path), true)
        XCTAssertNil(store.useWorktree(for: bogus), "stale pref must not be returned")

        let persisted = try JSONDecoder().decode(
            [String: Bool].self,
            from: XCTUnwrap(defaults.data(forKey: "RecentProjects.worktreePrefs.v1")))
        XCTAssertEqual(
            persisted, [tmpDir.path: true],
            "stale pref must have been removed from UserDefaults")
    }

    // MARK: - fixture helpers

    private func entry(path: String, lastUsed: Date = Date()) -> RecentProjectsStore.Entry {
        RecentProjectsStore.Entry(path: path, lastUsed: lastUsed)
    }

    private func seedEntries(_ entries: [RecentProjectsStore.Entry]) throws {
        let data = try JSONEncoder().encode(entries)
        defaults.set(data, forKey: "RecentProjects.v1")
    }

    private func seedLastLaunched(_ path: String) throws {
        defaults.set(path, forKey: "RecentProjects.lastLaunched.v1")
    }

    private func seedWorktreePrefs(_ prefs: [String: Bool]) throws {
        let data = try JSONEncoder().encode(prefs)
        defaults.set(data, forKey: "RecentProjects.worktreePrefs.v1")
    }
}
