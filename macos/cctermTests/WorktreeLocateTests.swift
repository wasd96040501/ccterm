import XCTest
@testable import ccterm

/// Covers `Worktree.locate(at:)`。
final class WorktreeLocateTests: XCTestCase {

    private var tmpRoot: URL!

    override func setUpWithError() throws {
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wtloc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root = tmpRoot, FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @discardableResult
    private func runGit(_ args: [String], cwd: String) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", cwd] + args
        let out = Pipe(); p.standardOutput = out
        let err = Pipe(); p.standardError = err
        try? p.run()
        p.waitUntilExit()
        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, o + e)
    }

    private func initRepo(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        _ = runGit(["init", "-b", "main"], cwd: path)
        _ = runGit(["config", "user.email", "t@example.com"], cwd: path)
        _ = runGit(["config", "user.name", "t"], cwd: path)
        let file = (path as NSString).appendingPathComponent("init.txt")
        try "x".write(toFile: file, atomically: true, encoding: .utf8)
        _ = runGit(["add", "-A"], cwd: path)
        _ = runGit(["commit", "-m", "init"], cwd: path)
    }

    func test_locate_returnsNilForMainRepo() throws {
        let repo = tmpRoot.appendingPathComponent("repo").path
        try initRepo(repo)

        XCTAssertNil(Worktree.locate(at: repo))
    }

    func test_locate_returnsNilForNonGitPath() throws {
        let plain = tmpRoot.appendingPathComponent("plain").path
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)

        XCTAssertNil(Worktree.locate(at: plain))
    }

    func test_locate_returnsInfoForCreatedWorktree() throws {
        let repo = tmpRoot.appendingPathComponent("repo").path
        try initRepo(repo)
        let wt = try Worktree.create(from: repo, sourceBranch: nil)

        guard let located = Worktree.locate(at: wt.path) else {
            XCTFail("locate should succeed for a managed worktree")
            return
        }

        XCTAssertEqual(located.name, wt.name)
        // baseRepo 两端 resolveSymlinks 后比较（tmp 路径 symlink 问题）
        XCTAssertEqual(
            URL(fileURLWithPath: located.baseRepo).resolvingSymlinksInPath().path,
            URL(fileURLWithPath: repo).resolvingSymlinksInPath().path
        )
        XCTAssertEqual(
            URL(fileURLWithPath: located.path).resolvingSymlinksInPath().path,
            URL(fileURLWithPath: wt.path).resolvingSymlinksInPath().path
        )
    }
}
