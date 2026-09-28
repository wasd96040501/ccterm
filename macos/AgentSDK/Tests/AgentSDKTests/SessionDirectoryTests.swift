import XCTest

@testable import AgentSDK

/// Listing over a synthetic projects directory laid out the way the CLI
/// writes it, noise included.
final class SessionDirectoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String, _ text: String = "{}", modified: TimeInterval? = nil) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let modified {
            try FileManager.default.setAttributes(
                [
                    .modificationDate: Date(timeIntervalSince1970: modified),
                    .creationDate: Date(timeIntervalSince1970: modified),
                ],
                ofItemAtPath: url.path)
        }
    }

    func testListsSessionsNewestFirstAndIgnoresNoise() throws {
        try write("-a/s1.jsonl", modified: 100)
        try write("-a/s2.jsonl", modified: 300)
        try write("-b/s3.jsonl", modified: 200)
        try write("-a/s1/tool-results/x.txt")
        try write("-a/memory/notes.md")
        try write("-a/script.js")
        try write("stray.jsonl")

        let sessions = SessionDirectory(url: root).sessions()
        XCTAssertEqual(sessions.map(\.id), ["s2", "s3", "s1"])
        XCTAssertEqual(sessions.last?.url.lastPathComponent, "s1.jsonl")
    }

    func testMissingDirectoryListsNothing() {
        XCTAssertEqual(SessionDirectory(url: root.appendingPathComponent("absent")).sessions(), [])
    }

    func testSubagentsAndWorkflows() throws {
        try write("-a/s.jsonl")
        try write("-a/s/subagents/agent-x.jsonl", modified: 20)
        try write("-a/s/subagents/agent-x.meta.json", #"{"agentType":"Explore","description":"Find it"}"#)
        try write("-a/s/subagents/agent-w.jsonl", modified: 10)
        try write("-a/s/subagents/workflows/wf_1/agent-y.jsonl")
        try write("-a/s/subagents/workflows/wf_1/agent-y.meta.json", #"{"description":"step"}"#)
        try write("-a/s/workflows/wf_1.json", #"{"runId":"wf_1","workflowName":"review","script":"…"}"#)
        try write("-a/s/subagents/workflows/wf_2/agent-z.jsonl")

        let session = try XCTUnwrap(SessionDirectory(url: root).sessions().first)
        let subagents = session.subagents()
        XCTAssertEqual(subagents.map(\.url.lastPathComponent), ["agent-w.jsonl", "agent-x.jsonl"])
        XCTAssertEqual(subagents[1].task, "Find it")
        XCTAssertEqual(subagents[1].agentType, "Explore")
        XCTAssertNil(subagents[0].task)

        let workflows = session.workflows().sorted { $0.id < $1.id }
        XCTAssertEqual(workflows.map(\.id), ["wf_1", "wf_2"])
        XCTAssertEqual(workflows[0].name, "review")
        XCTAssertEqual(workflows[0].agents.map(\.task), ["step"])
        XCTAssertNil(workflows[1].name)
    }

    func testDirectoryFromEnvironment() {
        XCTAssertEqual(
            SessionDirectory(environment: ["CLAUDE_CONFIG_DIR": "/cfg"]).url.path, "/cfg/projects")
        XCTAssertTrue(SessionDirectory(environment: [:]).url.path.hasSuffix("/.claude/projects"))
    }
}
