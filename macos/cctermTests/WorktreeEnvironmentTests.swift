import XCTest

@testable import ccterm

/// `Worktree` runs all of its git work (`git worktree add`, fetch, the
/// LFS `which` probe, post-create hooks) through `Worktree.runCommand`.
/// A GUI app launched from Finder/Dock inherits a minimal `PATH` that
/// omits Homebrew (`/opt/homebrew/bin`), so under that PATH git can't
/// find `git-lfs` and an LFS repo's `post-checkout` hook fails the whole
/// provision. `runCommand` therefore runs under the resolved login
/// environment (the same source the CLI subprocess uses), built by
/// `resolvedEnvironment(extra:)` / the pure `mergedEnvironment(...)`.
///
/// These tests pin the precedence contract (login base replaces the
/// process fallback, `extra` overrides both) and confirm `runCommand`
/// actually applies the resolved environment to the child process.
final class WorktreeEnvironmentTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Pure precedence contract

    func testMergedEnvironmentLoginBaseReplacesFallbackAndExtraOverrides() {
        let login = ["PATH": "/opt/homebrew/bin:/usr/bin", "SHARED": "from-login"]
        let process = ["PATH": "/usr/bin:/bin", "SHARED": "from-process", "ONLY_PROCESS": "x"]

        let merged = Worktree.mergedEnvironment(
            base: login, fallback: process, extra: ["SHARED": "from-extra"])

        XCTAssertEqual(
            merged["PATH"], "/opt/homebrew/bin:/usr/bin",
            "login env (with Homebrew) must replace the stunted process PATH")
        XCTAssertEqual(merged["SHARED"], "from-extra", "extra must override the base value")
        XCTAssertNil(
            merged["ONLY_PROCESS"],
            "base replaces fallback wholesale (matches the CLI's `login ?? process`); not a merge")
    }

    func testMergedEnvironmentFallsBackWhenLoginUnavailable() {
        let process = ["PATH": "/usr/bin:/bin"]

        let merged = Worktree.mergedEnvironment(
            base: nil, fallback: process, extra: ["EXTRA": "1"])

        XCTAssertEqual(merged["PATH"], "/usr/bin:/bin", "nil login base falls back to the process env")
        XCTAssertEqual(merged["EXTRA"], "1")
    }

    func testResolvedEnvironmentAlwaysCarriesPathAndLayersExtra() {
        let merged = Worktree.resolvedEnvironment(extra: ["CCTERM_ENV_PROBE": "y"])

        XCTAssertEqual(merged["CCTERM_ENV_PROBE"], "y", "extra must be layered on top")
        XCTAssertNotNil(
            merged["PATH"], "resolved env always carries a PATH (login env, or process fallback)")
    }

    // MARK: - runCommand actually applies the resolved environment

    func testRunCommandAppliesResolvedEnvironmentToSubprocess() {
        let marker = "marker-\(UUID().uuidString)"

        // `/usr/bin/env` with no args prints the child's environment.
        let result = Worktree.runCommand(
            "/usr/bin/env", [], cwd: "/", timeout: 15,
            extraEnv: ["CCTERM_ENV_PROBE": marker])

        XCTAssertEqual(result.exitCode, 0, "/usr/bin/env should succeed")
        XCTAssertTrue(
            result.stdout?.contains("CCTERM_ENV_PROBE=\(marker)") == true,
            "runCommand must pass the resolved environment (incl. extraEnv) to the subprocess")
    }
}
