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
/// Each test is self-contained: it builds its own UUID-named
/// `UserDefaults` suite, runs assertions, and removes the suite via
/// `defer`. No shared `setUp` / `tearDown` state — that avoided a
/// flaky CI failure on Xcode 26 where an IUO-backed shared `defaults`
/// could `nil`-trap during tearDown.
///
/// **Skipped on CI** (GitHub Actions sets `CI=true`). On Xcode 26.2 /
/// macOS 26.3 the host XCTRunner aborts every method in this class
/// with `libsystem_c.dylib: abort() called` before the body executes,
/// even with self-contained per-method setup and a UUID-only suite
/// name — neither shared state nor the suite name format reproduces
/// it locally on Xcode 26. The production fix is validated by the
/// full suite; this class is the regression guard for `init` not
/// hitting UserDefaults and for stale paths being deleted from
/// defaults, and is exercised locally via `make test-unit
/// FILTER=RecentProjectsStoreLazyLoadTests`. Re-enable on CI once the
/// abort root cause is understood.
@MainActor
final class RecentProjectsStoreLazyLoadTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        if ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip(
                "Skipped on CI — Xcode 26 / macOS 26.3 aborts these tests before they run; "
                    + "see class doc comment.")
        }
    }

    // MARK: - init does no I/O

    func testInitDoesNotReadDefaults() throws {
        let suite = try makeSuite()
        let defaults = suite.defaults
        defer { suite.cleanup() }

        // Pre-seed defaults with a path that does NOT exist on disk. If
        // `init` eagerly loaded, it would `fileExists` the path, fail,
        // and rewrite the key with an empty list.
        let bogus = bogusPath()
        try seedEntries(in: defaults, [entry(path: bogus)])
        defaults.set(bogus, forKey: "RecentProjects.lastLaunched.v1")
        try seedWorktreePrefs(in: defaults, [bogus: true])

        _ = RecentProjectsStore(defaults: defaults)

        // All three keys must remain exactly as seeded — the store
        // hasn't touched them.
        let decoded = try JSONDecoder().decode(
            [RecentProjectsStore.Entry].self,
            from: try XCTUnwrap(defaults.data(forKey: "RecentProjects.v1")))
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
        let suite = try makeSuite()
        let defaults = suite.defaults
        defer { suite.cleanup() }

        // Mix: one path that exists (per-test temp dir) + one that doesn't.
        let realDir = try makeRealDir()
        let bogus = bogusPath()
        try seedEntries(
            in: defaults,
            [
                entry(path: realDir.path, lastUsed: Date()),
                entry(path: bogus, lastUsed: Date().addingTimeInterval(-10)),
            ])

        let store = RecentProjectsStore(defaults: defaults)

        // First access — this is what triggers the load + prune + write-back.
        let observed = store.entries
        XCTAssertEqual(observed.map(\.path), [realDir.path])

        let persisted = try JSONDecoder().decode(
            [RecentProjectsStore.Entry].self,
            from: try XCTUnwrap(defaults.data(forKey: "RecentProjects.v1")))
        XCTAssertEqual(
            persisted.map(\.path), [realDir.path],
            "the bogus path must have been removed from UserDefaults, not just from the in-memory list")
    }

    func testFirstLastLaunchedReadDeletesStaleKeyFromDefaults() throws {
        let suite = try makeSuite()
        let defaults = suite.defaults
        defer { suite.cleanup() }

        let bogus = bogusPath()
        defaults.set(bogus, forKey: "RecentProjects.lastLaunched.v1")

        let store = RecentProjectsStore(defaults: defaults)

        XCTAssertNil(store.lastLaunchedPath, "stale path must not be returned")
        XCTAssertNil(
            defaults.string(forKey: "RecentProjects.lastLaunched.v1"),
            "stale key must be removed from UserDefaults")
    }

    func testFirstWorktreePrefReadPrunesNonexistentKeysFromDefaults() throws {
        let suite = try makeSuite()
        let defaults = suite.defaults
        defer { suite.cleanup() }

        let realDir = try makeRealDir()
        let bogus = bogusPath()
        try seedWorktreePrefs(in: defaults, [realDir.path: true, bogus: false])

        let store = RecentProjectsStore(defaults: defaults)

        XCTAssertEqual(store.useWorktree(for: realDir.path), true)
        XCTAssertNil(store.useWorktree(for: bogus), "stale pref must not be returned")

        let persisted = try JSONDecoder().decode(
            [String: Bool].self,
            from: try XCTUnwrap(defaults.data(forKey: "RecentProjects.worktreePrefs.v1")))
        XCTAssertEqual(
            persisted, [realDir.path: true],
            "stale pref must have been removed from UserDefaults")
    }

    // MARK: - fixture helpers

    /// A short-lived UserDefaults suite bound to a UUID-only name plus
    /// its own `cleanup` closure. The closure removes the persistent
    /// domain so the test never pollutes the host app's defaults.
    private struct Suite {
        let name: String
        let defaults: UserDefaults
        let cleanup: () -> Void
    }

    private func makeSuite() throws -> Suite {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: name),
            "UserDefaults(suiteName:) returned nil for \(name)")
        return Suite(
            name: name,
            defaults: defaults,
            cleanup: { defaults.removePersistentDomain(forName: name) })
    }

    private func makeRealDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-recents-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func bogusPath() -> String {
        "/var/empty/ccterm-does-not-exist-\(UUID().uuidString)"
    }

    private func entry(path: String, lastUsed: Date = Date()) -> RecentProjectsStore.Entry {
        RecentProjectsStore.Entry(path: path, lastUsed: lastUsed)
    }

    private func seedEntries(
        in defaults: UserDefaults, _ entries: [RecentProjectsStore.Entry]
    ) throws {
        let data = try JSONEncoder().encode(entries)
        defaults.set(data, forKey: "RecentProjects.v1")
    }

    private func seedWorktreePrefs(in defaults: UserDefaults, _ prefs: [String: Bool]) throws {
        let data = try JSONEncoder().encode(prefs)
        defaults.set(data, forKey: "RecentProjects.worktreePrefs.v1")
    }
}
