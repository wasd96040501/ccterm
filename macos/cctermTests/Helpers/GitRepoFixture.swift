import Foundation

/// A real git repository with one commit, in a unique temp directory.
final class GitRepoFixture {
    let url: URL

    /// A repository on `branch`, named `name` inside its own temp directory.
    init(name: String = "repo", branch: String = "main") throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git("init", "-q", "--initial-branch=\(branch)")
        try git("config", "user.email", "test@example.com")
        try git("config", "user.name", "test")
        try git("config", "commit.gpgsign", "false")
        try "seed".write(to: url.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        try git("add", "seed.txt")
        try git("commit", "-q", "-m", "initial")
    }

    func remove() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Runs git in the repository; throws with its output if it fails.
    @discardableResult
    func git(_ args: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", url.path] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "GitRepoFixture", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(args) failed: \(output)"])
        }
        return output
    }
}
