import Foundation
import XCTest

@testable import ccterm

/// Drives `GitProbe` against real `git init`-ed temp directories so the
/// full lifecycle — cheap `refresh`, heavy `loadHeavy`, cache invalidation
/// on folder change — is exercised the way the New Session compose card
/// would in production.
///
/// The first test is the regression net for the bug: on a fresh probe
/// instance, doing `refresh(nil)` first (mimicking the card mounting
/// before `Session.draft.cwd` has been seeded) followed by
/// `refresh(X) + loadHeavy(X)` must populate `branches`. The
/// pre-extraction code path reproduced "first entry shows empty picker"
/// because the probe state lived in SwiftUI `@State` storage on the
/// configurator, and the transition was sensitive to view re-render
/// timing; the extracted `@Observable` lets us drive the exact same
/// sequence in a single `XCTestCase` and assert on the result
/// deterministically.
@MainActor
final class GitProbeTests: XCTestCase {

    private var rootDir: URL?

    override func setUpWithError() throws {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        rootDir = root
    }

    override func tearDownWithError() throws {
        if let root = rootDir {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - Cold-mount sequence (regression net for the empty-picker bug)

    /// Mirrors what `ChatSessionViewController` +
    /// `NewSessionConfigurator` do on a fresh app launch: the
    /// configurator mounts before `Session.draft.cwd` has been seeded
    /// (so the first call is `refresh(nil)`), then the parent task
    /// fills in the draft's cwd and the second `refresh + loadHeavy`
    /// fires for the real repo path.
    ///
    /// After the second sequence, `branches` MUST contain the repo's
    /// branches. If this ever returns empty, the compose card's branch
    /// picker is empty on first entry until the user manually toggles
    /// folders.
    func testFirstEntryColdSequencePopulatesBranches() async throws {
        let repo = try makeGitRepo(name: "repo-a", branches: ["main", "feature/a", "feature/b"])
        let probe = GitProbe()

        // Phase 1 — card mounts with nil folderPath (the detail VC
        // hasn't seeded `Session.draft.cwd` yet).
        probe.refresh(folderPath: nil)
        await probe.loadHeavy(folderPath: nil)
        XCTAssertFalse(probe.isGitRepo, "nil folder must not flip the repo flag")
        XCTAssertTrue(probe.branches.isEmpty, "nil folder must leave branches empty")

        // Phase 2 — draft folder lands. Configurator's `.task(id:
        // folderPath)` re-fires with the real path.
        probe.refresh(folderPath: repo.path)
        await probe.loadHeavy(folderPath: repo.path)

        XCTAssertTrue(probe.isGitRepo, "real git folder must mark repo flag")
        XCTAssertEqual(probe.currentBranch, "main")
        XCTAssertEqual(
            Set(probe.branches), Set(["main", "feature/a", "feature/b"]),
            "branches must list every local ref after the heavy probe")
    }

    /// The exact production call shape the configurator uses inside its
    /// `.task(id: folderPath)`. Bug repro target: the configurator's
    /// `.task` runs as `refresh(folderPath:); await loadHeavy(folderPath:)`
    /// — the two calls are issued back-to-back inside a single closure,
    /// and `loadHeavy` reads probe state mutated by `refresh`. If state
    /// mutation has a visible ordering hazard (the @State storage bug
    /// the extraction was meant to neutralize), `branches` ends up empty.
    func testTaskClosureShapePopulatesBranches() async throws {
        let repo = try makeGitRepo(name: "task-repo", branches: ["main", "develop"])
        let probe = GitProbe()

        // Same closure shape the configurator uses.
        let run: () async -> Void = {
            probe.refresh(folderPath: repo.path)
            await probe.loadHeavy(folderPath: repo.path)
        }
        await run()

        XCTAssertEqual(Set(probe.branches), Set(["main", "develop"]))
        XCTAssertEqual(probe.currentBranch, "main")
    }

    // MARK: - Folder switching

    /// A → B → A — every folder change must invalidate the heavy cache
    /// and re-probe. If `heavyGitLoadedForFolder` gating drifts, the
    /// switch-back path silently keeps stale data; the regression
    /// surface for that is this test going from a 1-branch repo to a
    /// 3-branch repo and back.
    func testFolderSwitchingInvalidatesHeavyCache() async throws {
        let repoA = try makeGitRepo(name: "repo-a", branches: ["main"])
        let repoB = try makeGitRepo(name: "repo-b", branches: ["main", "x", "y", "z"])
        let probe = GitProbe()

        probe.refresh(folderPath: repoA.path)
        await probe.loadHeavy(folderPath: repoA.path)
        XCTAssertEqual(Set(probe.branches), Set(["main"]))

        probe.refresh(folderPath: repoB.path)
        await probe.loadHeavy(folderPath: repoB.path)
        XCTAssertEqual(
            Set(probe.branches), Set(["main", "x", "y", "z"]),
            "switching to repoB must replace the cached branch list, not append")

        probe.refresh(folderPath: repoA.path)
        await probe.loadHeavy(folderPath: repoA.path)
        XCTAssertEqual(
            Set(probe.branches), Set(["main"]),
            "switching back to repoA must re-probe (heavy cache is single-slot)")
    }

    /// Idempotent re-probe — calling `loadHeavy` twice for the same
    /// folder without an intervening `refresh` to a different path must
    /// not re-shell. We can't directly observe subprocess counts, but
    /// branch list identity is a reasonable proxy: a re-shell would
    /// re-read the same refs and produce the same array.
    func testLoadHeavyIsIdempotentForSamePath() async throws {
        let repo = try makeGitRepo(name: "idem-repo", branches: ["main", "extra"])
        let probe = GitProbe()

        probe.refresh(folderPath: repo.path)
        await probe.loadHeavy(folderPath: repo.path)
        let first = probe.branches

        await probe.loadHeavy(folderPath: repo.path)
        XCTAssertEqual(
            probe.branches, first,
            "repeated loadHeavy for the same path must keep the cached list intact")
    }

    // MARK: - Negative paths

    /// A folder that exists but isn't a git repo must leave both flags
    /// false and never shell out (`loadHeavy` short-circuits on
    /// `isGitRepo == false`).
    func testNonGitFolderStaysEmpty() async throws {
        let root = try requireRoot()
        let plain = root.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

        let probe = GitProbe()
        probe.refresh(folderPath: plain.path)
        await probe.loadHeavy(folderPath: plain.path)

        XCTAssertFalse(probe.isGitRepo)
        XCTAssertNil(probe.currentBranch)
        XCTAssertTrue(probe.branches.isEmpty)
    }

    /// A folder that no longer exists on disk also stays empty —
    /// production removes the entry from recents, but the probe itself
    /// just clears its state.
    func testMissingFolderStaysEmpty() async throws {
        let root = try requireRoot()
        let gone = root.appendingPathComponent("does-not-exist")

        let probe = GitProbe()
        probe.refresh(folderPath: gone.path)
        await probe.loadHeavy(folderPath: gone.path)

        XCTAssertFalse(probe.isGitRepo)
        XCTAssertTrue(probe.branches.isEmpty)
    }

    // MARK: - Helpers

    /// Initialize a real git repo under `rootDir`, create the named
    /// branches off an initial commit, and leave HEAD pointed at the
    /// first entry of `branches`. Returns the repo URL.
    private func makeGitRepo(name: String, branches: [String]) throws -> URL {
        precondition(!branches.isEmpty)
        let root = try requireRoot()
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try runGit(in: dir, "init", "-q", "--initial-branch=\(branches[0])")
        try runGit(in: dir, "config", "user.email", "test@example.com")
        try runGit(in: dir, "config", "user.name", "test")
        try runGit(in: dir, "config", "commit.gpgsign", "false")

        // Seed an initial commit so refs are valid.
        let seed = dir.appendingPathComponent("seed.txt")
        try "seed".write(to: seed, atomically: true, encoding: .utf8)
        try runGit(in: dir, "add", "seed.txt")
        try runGit(in: dir, "commit", "-q", "-m", "initial")

        // Materialize every extra branch off the initial commit. The
        // first entry is already the active branch from `init
        // --initial-branch`, so it's skipped.
        for branch in branches.dropFirst() {
            try runGit(in: dir, "branch", branch)
        }
        return dir
    }

    @discardableResult
    private func runGit(in dir: URL, _ args: String...) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", dir.path] + args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard proc.terminationStatus == 0 else {
            let out = String(data: data, encoding: .utf8) ?? "<no output>"
            throw NSError(
                domain: "GitProbeTests",
                code: Int(proc.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(args) failed: \(out)"])
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func requireRoot() throws -> URL {
        guard let root = rootDir else {
            throw XCTSkip("rootDir not set up")
        }
        return root
    }
}
