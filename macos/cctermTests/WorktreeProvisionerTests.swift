import XCTest

@testable import ccterm

/// Exercises `WorktreeProvisioner.provision` through its injectable
/// `creator` seam — no real `git worktree add`, no shell-out. The
/// `creator` closure is the only place where production hits git, so
/// flipping it lets these tests pin down:
/// - nil origin short-circuits to `.notGitRepository` without touching
///   the creator
/// - successful creator → `.success`
/// - thrown creator → `.failure` with the same error
/// - collision-retry shape: creator can return a `Worktree` whose `name`
///   differs from `preferredName`, and the caller (SessionHandle2)
///   detects that by comparing `wt.name` against the proposed name
final class WorktreeProvisionerTests: XCTestCase {

    /// Lock-protected capture for `creator` arguments. The creator is
    /// `@Sendable` and synchronous (production calls `Worktree.create`
    /// which is sync), so we cannot `await` inside it. A lock-backed
    /// `@unchecked Sendable` class is the simplest correct approach.
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: Int = 0
        private var _origin: String?
        private var _source: String?
        private var _preferred: String?

        func record(origin: String, source: String?, preferred: String) {
            lock.lock()
            defer { lock.unlock() }
            _calls += 1
            _origin = origin
            _source = source
            _preferred = preferred
        }

        var calls: Int { lock.withLock { _calls } }
        var origin: String? { lock.withLock { _origin } }
        var source: String? { lock.withLock { _source } }
        var preferred: String? { lock.withLock { _preferred } }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - nil origin

    func testNilOriginFailsWithoutCallingCreator() async {
        let capture = Capture()

        let outcome = await WorktreeProvisioner.provision(
            origin: nil,
            sourceBranch: nil,
            preferredName: "dummy-name"
        ) { origin, source, preferred in
            capture.record(origin: origin, source: source, preferred: preferred)
            return Worktree(
                path: "/tmp/x", name: "x",
                baseRepo: "/tmp/y", sourceBranch: nil)
        }

        XCTAssertEqual(capture.calls, 0, "nil origin must short-circuit before creator runs")
        switch outcome {
        case .failure(let err as Worktree.Error):
            if case .notGitRepository = err {
                // ok
            } else {
                XCTFail("expected notGitRepository, got \(err)")
            }
        default:
            XCTFail("expected .failure(.notGitRepository), got \(outcome)")
        }
    }

    // MARK: - success

    func testCreatorSuccessReturnsValue() async {
        let expected = Worktree(
            path: "/tmp/repos/base-default-foo-a1b2c3",
            name: "default-foo-a1b2c3",
            baseRepo: "/tmp/repos/base",
            sourceBranch: "main"
        )
        let outcome = await WorktreeProvisioner.provision(
            origin: "/tmp/repos/base",
            sourceBranch: "main",
            preferredName: "default-foo-a1b2c3"
        ) { _, _, _ in expected }

        switch outcome {
        case .success(let wt):
            XCTAssertEqual(wt, expected)
        case .failure(let err):
            XCTFail("expected .success, got .failure(\(err))")
        }
    }

    func testForwardsArgsIntoCreator() async {
        let capture = Capture()

        _ = await WorktreeProvisioner.provision(
            origin: "/repo",
            sourceBranch: "feature/branch",
            preferredName: "happy-mendel-9c1e2a"
        ) { origin, source, preferred in
            capture.record(origin: origin, source: source, preferred: preferred)
            return Worktree(
                path: "/tmp/x", name: "x",
                baseRepo: "/tmp/y", sourceBranch: source)
        }

        XCTAssertEqual(capture.origin, "/repo")
        XCTAssertEqual(capture.source, "feature/branch")
        XCTAssertEqual(capture.preferred, "happy-mendel-9c1e2a")
    }

    // MARK: - failure

    func testCreatorThrowingReturnsFailure() async {
        struct Boom: Error, Equatable {}
        let outcome = await WorktreeProvisioner.provision(
            origin: "/repo",
            sourceBranch: nil,
            preferredName: "any"
        ) { _, _, _ in throw Boom() }

        switch outcome {
        case .failure(let err):
            XCTAssertTrue(err is Boom, "expected Boom, got \(err)")
        case .success(let wt):
            XCTFail("expected .failure, got .success(\(wt))")
        }
    }

    func testCreatorWorktreeErrorPropagates() async {
        let outcome = await WorktreeProvisioner.provision(
            origin: "/repo",
            sourceBranch: nil,
            preferredName: "x"
        ) { _, _, _ in
            throw Worktree.Error.git(stderr: "fatal: branch conflict", isBranchConflict: true)
        }

        switch outcome {
        case .failure(let err as Worktree.Error):
            if case .git(let stderr, let isConflict) = err {
                XCTAssertEqual(stderr, "fatal: branch conflict")
                XCTAssertTrue(isConflict)
            } else {
                XCTFail("expected .git, got \(err)")
            }
        default:
            XCTFail("expected .failure(Worktree.Error.git), got \(outcome)")
        }
    }

    // MARK: - collision-retry name shape

    func testCreatorMayReturnDifferentNameThanPreferred() async {
        // Production: `Worktree.create` may pick a fresh name when the
        // preferred one collides on the branch ref. The provisioner is
        // transparent — it just returns whatever the creator built.
        // The caller (SessionHandle2) then compares `wt.name` to its
        // pre-computed `proposedName` to detect the mismatch.
        let outcome = await WorktreeProvisioner.provision(
            origin: "/repo",
            sourceBranch: nil,
            preferredName: "first-pick-aaa111"
        ) { _, _, _ in
            Worktree(
                path: "/tmp/repo/.worktrees/recovered-bbb222",
                name: "recovered-bbb222",
                baseRepo: "/repo",
                sourceBranch: nil)
        }

        switch outcome {
        case .success(let wt):
            XCTAssertNotEqual(wt.name, "first-pick-aaa111")
            XCTAssertEqual(wt.name, "recovered-bbb222")
        case .failure(let err):
            XCTFail("expected .success after retry, got .failure(\(err))")
        }
    }
}

// `NSLock.withLock` helper — Foundation does not ship one on macOS 14.
// Trivial wrapper so the test code reads cleanly.
extension NSLock {
    fileprivate func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
