import AgentSDK
import Combine
import XCTest

@testable import ccterm

/// The library tree `LibraryStore` builds from a synthetic session directory,
/// and when it publishes.
@MainActor
final class LibraryStoreTests: XCTestCase {
    private var root: URL!
    private var store: LibraryStore!
    private var emissions: [[LibraryNode]] = []
    private var cancellables = Set<AnyCancellable>()

    override func setUpWithError() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The listing reports `/private/var/…`; `resolvingSymlinksInPath()`
        // would strip that prefix rather than add it.
        let resolved = try XCTUnwrap(realpath(directory.path, nil))
        root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        free(resolved)
        store = LibraryStore(directory: SessionDirectory(url: root))
        store.$nodes.sink { [weak self] in self?.emissions.append($0) }.store(in: &cancellables)
    }

    override func tearDownWithError() throws {
        store.stop()
        cancellables.removeAll()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixture

    private func write(_ path: String, _ lines: [String], modified: TimeInterval? = nil) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(lines.joined(separator: "\n").utf8).write(to: url)
        if let modified {
            let date = Date(timeIntervalSince1970: modified)
            try FileManager.default.setAttributes(
                [.modificationDate: date, .creationDate: date], ofItemAtPath: url.path)
        }
    }

    private func user(cwd: String) -> String {
        #"{"type":"user","uuid":"u","parentUuid":null,"sessionId":"s","cwd":"\#(cwd)","message":{"role":"user","content":"hi"}}"#
    }

    private func path(_ relative: String) -> String {
        root.appendingPathComponent(relative).path
    }

    /// Two project directories that are one repository (one run in a
    /// worktree), a second repository, and a session with no working
    /// directory; the newest session spawned a subagent and a workflow run.
    private func writeFixture() throws {
        try write(
            "-x-repo/s1.jsonl",
            [user(cwd: "/x/repo"), #"{"type":"custom-title","customTitle":"Named","sessionId":"s1"}"#],
            modified: 300)
        try write("-x-repo/s1/subagents/agent-a.jsonl", [user(cwd: "/x/repo")])
        try write("-x-repo/s1/subagents/agent-a.meta.json", [#"{"description":"Find it","agentType":"Explore"}"#])
        try write("-x-repo/s1/subagents/workflows/wf_1/agent-b.jsonl", [user(cwd: "/x/repo")])
        try write("-x-repo/s1/workflows/wf_1.json", [#"{"workflowName":"review"}"#])
        try write(
            "-x-repo--claude-worktrees-wt-sub/s2.jsonl",
            [user(cwd: "/x/repo/.claude/worktrees/wt/sub"), #"{"type":"ai-title","aiTitle":"Auto","sessionId":"s2"}"#],
            modified: 200)
        try write(
            "-y-other/s3.jsonl",
            [user(cwd: "/y/other"), #"{"type":"last-prompt","lastPrompt":"fix it","sessionId":"s3"}"#],
            modified: 100)
        try write("-z/s4.jsonl", [#"{"type":"ai-title","aiTitle":"Nowhere","sessionId":"s4"}"#], modified: 400)
    }

    private var expectedTree: [LibraryNode] {
        let s1 = path("-x-repo/s1.jsonl")
        let subagents = LibraryNode(
            id: s1 + "/subagents", kind: .subagents, title: String(localized: "Subagents"), transcriptURL: nil,
            children: [agent("-x-repo/s1/subagents/agent-a.jsonl", "Find it")])
        let workflow = LibraryNode(
            id: s1 + "/wf_1", kind: .workflow, title: "review", transcriptURL: nil,
            children: [agent("-x-repo/s1/subagents/workflows/wf_1/agent-b.jsonl", "agent-b")])
        return [
            LibraryNode(
                id: "/x/repo", kind: .project, title: "repo", transcriptURL: nil,
                children: [
                    session("-x-repo/s1.jsonl", "Named", children: [subagents, workflow]),
                    session("-x-repo--claude-worktrees-wt-sub/s2.jsonl", "Auto"),
                ]),
            LibraryNode(
                id: "/y/other", kind: .project, title: "other", transcriptURL: nil,
                children: [session("-y-other/s3.jsonl", "fix it")]),
        ]
    }

    private func session(_ relative: String, _ title: String, children: [LibraryNode] = []) -> LibraryNode {
        let url = root.appendingPathComponent(relative)
        return LibraryNode(id: url.path, kind: .session, title: title, transcriptURL: url, children: children)
    }

    private func agent(_ relative: String, _ title: String) -> LibraryNode {
        let url = root.appendingPathComponent(relative)
        return LibraryNode(id: url.path, kind: .agent, title: title, transcriptURL: url, children: [])
    }

    private func waitForNodes(_ predicate: @escaping ([LibraryNode]) -> Bool) async {
        let arrived = expectation(description: "nodes")
        let subscription = store.$nodes.first(where: predicate).sink { _ in arrived.fulfill() }
        await fulfillment(of: [arrived], timeout: 10)
        subscription.cancel()
    }

    // MARK: - Tests

    func testBuildsTheTreeFromTheDirectory() async throws {
        try writeFixture()
        store.start()
        await waitForNodes { !$0.isEmpty }
        XCTAssertEqual(store.nodes, expectedTree)
        XCTAssertEqual(emissions, [[], expectedTree])
    }

    func testAnEmptyDirectoryPublishesNothingNew() async {
        store.start()
        let republished = expectation(description: "republished")
        republished.isInverted = true
        let subscription = store.$nodes.dropFirst().sink { _ in republished.fulfill() }
        await fulfillment(of: [republished], timeout: 2)
        subscription.cancel()
        XCTAssertEqual(emissions, [[]])
    }

    func testAChangeThatLeavesTheTreeAloneIsNotPublished() async throws {
        try writeFixture()
        store.start()
        await waitForNodes { !$0.isEmpty }

        let republished = expectation(description: "republished")
        republished.isInverted = true
        let subscription = store.$nodes.dropFirst().sink { _ in republished.fulfill() }
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent("-x-repo/s1.jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n{\"type\":\"mode\",\"mode\":\"normal\",\"sessionId\":\"s1\"}".utf8))
        try handle.close()
        await fulfillment(of: [republished], timeout: 3)
        subscription.cancel()
        XCTAssertEqual(emissions.count, 2)
    }

    func testANewSessionIsPublished() async throws {
        try writeFixture()
        store.start()
        await waitForNodes { !$0.isEmpty }

        try write(
            "-y-other/s5.jsonl", [user(cwd: "/y/other"), #"{"type":"ai-title","aiTitle":"Fresh","sessionId":"s5"}"#])
        await waitForNodes { $0.first?.title == "other" }
        XCTAssertEqual(store.nodes.first?.children.first?.title, "Fresh")
    }
}
