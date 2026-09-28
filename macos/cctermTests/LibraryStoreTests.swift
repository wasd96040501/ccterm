import AgentSDK
import Combine
import XCTest

@testable import ccterm

/// The library tree `LibraryStore` builds from a synthetic session directory,
/// and when it publishes.
@MainActor
final class LibraryStoreTests: XCTestCase {
    typealias Rows = SessionDirectoryFixture

    private var fixture: SessionDirectoryFixture!
    private var store: LibraryStore!
    private var emissions: [[LibraryNode]] = []
    private var cancellables = Set<AnyCancellable>()

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try SessionDirectoryFixture()
        store = LibraryStore(directory: fixture.directory)
        store.$nodes.sink { [weak self] in self?.emissions.append($0) }.store(in: &cancellables)
    }

    override func tearDownWithError() throws {
        store.stop()
        cancellables.removeAll()
        fixture.remove()
    }

    /// Two project directories that are one repository (one run in a
    /// worktree), a second repository, and a session with no working
    /// directory; the newest session spawned a subagent and a workflow run.
    static func writeLibrary(_ fixture: SessionDirectoryFixture) throws {
        try fixture.write("-x-repo/s1.jsonl", [Rows.user("u"), Rows.customTitle("Named")], modified: 300)
        try fixture.write("-x-repo/s1/subagents/agent-a.jsonl", [Rows.user("u")])
        try fixture.write(
            "-x-repo/s1/subagents/agent-a.meta.json", [#"{"description":"Find it","agentType":"Explore"}"#])
        try fixture.write("-x-repo/s1/subagents/workflows/wf_1/agent-b.jsonl", [Rows.user("u")])
        try fixture.write("-x-repo/s1/workflows/wf_1.json", [#"{"workflowName":"review"}"#])
        try fixture.write(
            "-x-repo--claude-worktrees-wt-sub/s2.jsonl",
            [Rows.user("u", cwd: "/x/repo/.claude/worktrees/wt/sub"), Rows.aiTitle("Auto")], modified: 200)
        try fixture.write(
            "-y-other/s3.jsonl", [Rows.user("u", cwd: "/y/other"), Rows.lastPrompt("fix it")], modified: 100)
        try fixture.write("-z/s4.jsonl", [Rows.aiTitle("Nowhere")], modified: 400)
    }

    private var expectedTree: [LibraryNode] {
        let s1 = fixture.url("-x-repo/s1.jsonl").path
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
        let url = fixture.url(relative)
        return LibraryNode(id: url.path, kind: .session, title: title, transcriptURL: url, children: children)
    }

    private func agent(_ relative: String, _ title: String) -> LibraryNode {
        let url = fixture.url(relative)
        return LibraryNode(id: url.path, kind: .agent, title: title, transcriptURL: url, children: [])
    }

    private func waitForNodes(_ predicate: @escaping ([LibraryNode]) -> Bool) async {
        let arrived = expectation(description: "nodes")
        let subscription = store.$nodes.first(where: predicate).sink { _ in arrived.fulfill() }
        await fulfillment(of: [arrived], timeout: 10)
        subscription.cancel()
    }

    private func expectNoPublish(within timeout: TimeInterval, after change: () throws -> Void) async rethrows {
        let republished = expectation(description: "republished")
        republished.isInverted = true
        let subscription = store.$nodes.dropFirst().sink { _ in republished.fulfill() }
        try change()
        await fulfillment(of: [republished], timeout: timeout)
        subscription.cancel()
    }

    // MARK: - Tests

    func testBuildsTheTreeFromTheDirectory() async throws {
        try Self.writeLibrary(fixture)
        store.start()
        await waitForNodes { !$0.isEmpty }
        XCTAssertEqual(store.nodes, expectedTree)
        XCTAssertEqual(emissions, [[], expectedTree])
    }

    func testAnEmptyDirectoryPublishesNothingNew() async {
        await expectNoPublish(within: 2) { store.start() }
        XCTAssertEqual(emissions, [[]])
    }

    func testAChangeThatLeavesTheTreeAloneIsNotPublished() async throws {
        try Self.writeLibrary(fixture)
        store.start()
        await waitForNodes { !$0.isEmpty }

        // The newest session gains a row that changes nothing shown.
        try await expectNoPublish(within: 3) {
            let handle = try FileHandle(forWritingTo: fixture.url("-x-repo/s1.jsonl"))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(("\n" + Rows.row(["type": "mode", "mode": "normal"])).utf8))
            try handle.close()
        }
        XCTAssertEqual(emissions.count, 2)
    }

    func testASubagentStartedLaterIsPublishedUnderItsSession() async throws {
        try Self.writeLibrary(fixture)
        store.start()
        await waitForNodes { !$0.isEmpty }

        // Only the agent's own files are written; the session's is untouched.
        try fixture.write("-x-repo/s1/subagents/agent-c.jsonl", [Rows.user("u")])
        try fixture.write("-x-repo/s1/subagents/agent-c.meta.json", [#"{"description":"Later"}"#])
        await waitForNodes { nodes in
            nodes.first?.children.first?.children.first?.children.map(\.title).contains("Later") == true
        }
    }

    func testANewSessionIsPublished() async throws {
        try Self.writeLibrary(fixture)
        store.start()
        await waitForNodes { !$0.isEmpty }

        try fixture.write("-y-other/s5.jsonl", [Rows.user("u", cwd: "/y/other"), Rows.aiTitle("Fresh")])
        await waitForNodes { $0.first?.title == "other" }
        XCTAssertEqual(store.nodes.first?.children.first?.title, "Fresh")
    }
}
