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
        store = LibraryStore(directories: Just(fixture.directory).eraseToAnyPublisher())
        store.$nodes.sink { [weak self] in self?.emissions.append($0) }.store(in: &cancellables)
    }

    override func tearDownWithError() throws {
        store.stop()
        cancellables.removeAll()
        fixture.remove()
    }

    /// Two project directories that are one repository (one run in a
    /// worktree), a second repository, and — none of them shown — sessions
    /// with no working directory, run through `claude -p`, or run in a
    /// temporary or hidden directory. The newest shown session spawned a
    /// subagent and a workflow run.
    static func writeLibrary(_ fixture: SessionDirectoryFixture) throws {
        let printed = Rows.row([
            "type": "user", "uuid": "u", "parentUuid": NSNull(), "sessionId": "s", "cwd": "/x/repo",
            "entrypoint": "sdk-cli", "message": ["role": "user", "content": "hi"],
        ])
        try fixture.write("-x-repo/s7.jsonl", [printed, Rows.aiTitle("Printed")], modified: 500)
        try fixture.write("-private-tmp-probe/s8.jsonl", [Rows.user("u", cwd: "/private/tmp/probe")], modified: 500)
        try fixture.write("-u--cache-bench/s9.jsonl", [Rows.user("u", cwd: "/u/.cache/bench")], modified: 500)
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
                    session("-x-repo--claude-worktrees-wt-sub/s2.jsonl", "Auto", worktreeBranch: "worktree-wt"),
                ]),
            LibraryNode(
                id: "/y/other", kind: .project, title: "other", transcriptURL: nil,
                children: [session("-y-other/s3.jsonl", "fix it")]),
        ]
    }

    private func session(
        _ relative: String, _ title: String, children: [LibraryNode] = [], worktreeBranch: String? = nil
    ) -> LibraryNode {
        let url = fixture.url(relative)
        return LibraryNode(
            id: url.path, kind: .session, title: title, transcriptURL: url, children: children,
            worktreeBranch: worktreeBranch)
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

    func testAWorktreeSessionIsListedUnderItsRepositoryWithTheBranchItRecorded() async throws {
        let recorded = Rows.row([
            "type": "user", "uuid": "u", "parentUuid": NSNull(), "sessionId": "s",
            "cwd": "/x/repo/.claude/worktrees/quiet-otter", "gitBranch": "worktree-quiet-otter",
            "message": ["role": "user", "content": "hi"],
        ])
        try fixture.write("-x-repo--claude-worktrees-quiet-otter/w1.jsonl", [recorded, Rows.aiTitle("In a worktree")])
        try fixture.write("-x-repo/w2.jsonl", [Rows.user("u"), Rows.aiTitle("In place")], modified: 50)
        store.start()
        await waitForNodes { !$0.isEmpty }
        let repository = try XCTUnwrap(store.nodes.first)
        XCTAssertEqual(repository.id, "/x/repo")
        XCTAssertEqual(repository.children.map(\.title).sorted(), ["In a worktree", "In place"])
        XCTAssertEqual(
            repository.children.first { $0.title == "In a worktree" }?.worktreeBranch, "worktree-quiet-otter")
        XCTAssertNil(repository.children.first { $0.title == "In place" }?.worktreeBranch)
    }

    func testBuildsTheTreeFromTheDirectory() async throws {
        try Self.writeLibrary(fixture)
        store.start()
        await waitForNodes { !$0.isEmpty }
        XCTAssertEqual(store.nodes, expectedTree)
        XCTAssertEqual(emissions, [[], expectedTree])
    }

    /// Loaded once the first read lands, with the tree it read already there.
    func testIsLoadedWithTheFirstTree() async throws {
        try Self.writeLibrary(fixture)
        XCTAssertFalse(store.isLoaded)
        let loaded = expectation(description: "loaded")
        var treeWhenLoaded: [LibraryNode]?
        let subscription = store.$isLoaded.first { $0 }.sink { [store] _ in
            treeWhenLoaded = store?.nodes
            loaded.fulfill()
        }
        store.start()
        await fulfillment(of: [loaded], timeout: 10)
        subscription.cancel()
        XCTAssertEqual(treeWhenLoaded, expectedTree)
    }

    /// An empty directory is loaded too: read, and nothing in it.
    func testAnEmptyDirectoryIsLoaded() async {
        let loaded = expectation(description: "loaded")
        let subscription = store.$isLoaded.first { $0 }.sink { _ in loaded.fulfill() }
        store.start()
        await fulfillment(of: [loaded], timeout: 10)
        subscription.cancel()
        XCTAssertEqual(store.nodes, [])
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

    // MARK: - Index

    /// A launch through an index builds what reading every session builds —
    /// the sessions left out stay out — and so does the next launch, through
    /// the index the first left.
    func testALaunchThroughTheIndexBuildsTheSameTree() async throws {
        try Self.writeLibrary(fixture)
        let index = try indexURL()

        let first = await launch(indexedAt: index)
        XCTAssertEqual(first, expectedTree)
        let second = await launch(indexedAt: index)
        XCTAssertEqual(second, expectedTree)
    }

    /// A transcript is read again only when its date moved; one that kept its
    /// date is what it read as last time.
    func testALaunchReadsOnlyTranscriptsWrittenSinceTheIndex() async throws {
        try Self.writeLibrary(fixture)
        let index = try indexURL()
        _ = await launch(indexedAt: index)

        try fixture.write("-x-repo/s1.jsonl", [Rows.user("u"), Rows.customTitle("Renamed")], modified: 301)
        try fixture.write(
            "-y-other/s3.jsonl", [Rows.user("u", cwd: "/y/other"), Rows.lastPrompt("same date")], modified: 100)
        let nodes = await launch(indexedAt: index)

        XCTAssertEqual(nodes.first?.children.first?.title, "Renamed")
        XCTAssertEqual(nodes.last?.children.first?.title, "fix it")
    }

    /// Side transcripts come and go without their session's transcript
    /// moving: the index answers for them first, the disk after.
    func testASubagentStartedBetweenLaunchesIsShown() async throws {
        try Self.writeLibrary(fixture)
        let index = try indexURL()
        _ = await launch(indexedAt: index)

        try fixture.write("-y-other/s3/subagents/agent-c.jsonl", [Rows.user("u")])
        let nodes = await launch(indexedAt: index) { $0.last?.children.first?.children.isEmpty == false }

        XCTAssertEqual(nodes.last?.children.first?.children.first?.kind, .subagents)
    }

    func testAnUnreadableIndexReadsEverySession() async throws {
        try Self.writeLibrary(fixture)
        let index = try indexURL()
        try Data("not a plist".utf8).write(to: index)

        let nodes = await launch(indexedAt: index)
        XCTAssertEqual(nodes, expectedTree)
    }

    // MARK: - Changing directory

    private func titles(_ nodes: [LibraryNode]) -> [String] {
        nodes.flatMap(\.children).map(\.title)
    }

    /// A second directory with one session, `title`.
    private func otherFixture(_ title: String) throws -> SessionDirectoryFixture {
        let other = try SessionDirectoryFixture()
        addTeardownBlock { other.remove() }
        try other.write("-o-proj/o1.jsonl", [Rows.user("u", cwd: "/o/proj"), Rows.customTitle(title)], modified: 50)
        return other
    }

    private func nodes(
        of store: LibraryStore, where predicate: @escaping ([LibraryNode]) -> Bool
    ) async
        -> [LibraryNode]
    {
        let arrived = expectation(description: "nodes")
        var published: [LibraryNode] = []
        let subscription = store.$nodes.first(where: predicate).sink {
            published = $0
            arrived.fulfill()
        }
        await fulfillment(of: [arrived], timeout: 10)
        subscription.cancel()
        return published
    }

    /// The library follows the directory it is given: the second one's
    /// sessions replace the first's.
    func testASwitchedDirectoryShowsOnlyItsOwnSessions() async throws {
        try Self.writeLibrary(fixture)
        let other = try otherFixture("Second")
        let directories = CurrentValueSubject<SessionDirectory, Never>(fixture.directory)
        let store = LibraryStore(directories: directories.eraseToAnyPublisher())
        defer { store.stop() }
        store.start()
        let first = await nodes(of: store) { !$0.isEmpty }
        XCTAssertEqual(first, expectedTree)

        directories.send(other.directory)
        let second = await nodes(of: store) { self.titles($0) == ["Second"] }
        XCTAssertEqual(second.map(\.id), ["/o/proj"])

        // A change in the second directory is followed; one in the first isn't.
        try fixture.write("-y-other/s5.jsonl", [Rows.user("u", cwd: "/y/other")], modified: 900)
        try other.write("-o-proj/o2.jsonl", [Rows.user("u", cwd: "/o/proj"), Rows.customTitle("Third")], modified: 60)
        let third = await nodes(of: store) { self.titles($0).count == 2 }
        XCTAssertEqual(Set(titles(third)), ["Second", "Third"])
    }

    /// What the first directory's task read after the switch is dropped.
    func testAResultFromThePreviousDirectoryArrivingLateIsDropped() async throws {
        try Self.writeLibrary(fixture)
        let other = try otherFixture("Second")
        let directories = CurrentValueSubject<SessionDirectory, Never>(fixture.directory)
        let store = LibraryStore(directories: directories.eraseToAnyPublisher())
        defer { store.stop() }
        var seen: [[LibraryNode]] = []
        let subscription = store.$nodes.sink { seen.append($0) }
        defer { subscription.cancel() }

        store.start()
        directories.send(other.directory)  // before the first directory's read lands
        _ = await nodes(of: store) { self.titles($0) == ["Second"] }
        // Long enough for the first directory's read to have finished.
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(titles(store.nodes), ["Second"])
        XCTAssertFalse(seen.contains { !$0.isEmpty && titles($0) != ["Second"] })
    }

    /// Each directory keeps its own index, named by its path.
    func testEachDirectoryHasItsOwnIndexFile() async throws {
        try Self.writeLibrary(fixture)
        let other = try otherFixture("Second")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let directories = CurrentValueSubject<SessionDirectory, Never>(fixture.directory)
        let store = LibraryStore(directories: directories.eraseToAnyPublisher(), indexDirectory: folder)
        defer { store.stop() }
        store.start()
        let firstIndex = LibraryStore.indexURL(for: fixture.directory, in: folder)
        let secondIndex = LibraryStore.indexURL(for: other.directory, in: folder)
        XCTAssertNotEqual(firstIndex, secondIndex)

        func exists(_ url: URL) -> XCTNSPredicateExpectation {
            XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: url.path) }, object: nil)
        }
        await fulfillment(of: [exists(firstIndex)], timeout: 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondIndex.path))
        directories.send(other.directory)
        await fulfillment(of: [exists(secondIndex)], timeout: 10)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstIndex.path))
        XCTAssertEqual(firstIndex.deletingLastPathComponent().path, folder.path)
        XCTAssertTrue(firstIndex.lastPathComponent.hasPrefix("LibraryIndex-"))
    }

    /// The fixture's index in a unique folder beside no session directory: a
    /// file in one would read as a change to it.
    private func indexURL() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return LibraryStore.indexURL(for: fixture.directory, in: folder)
    }

    /// The first tree `predicate` holds for that a store started over the
    /// fixture, with the index at `url`, publishes — once there is an index
    /// there. The store is stopped after.
    private func launch(
        indexedAt url: URL, until predicate: @escaping ([LibraryNode]) -> Bool = { !$0.isEmpty }
    ) async -> [LibraryNode] {
        let store = LibraryStore(
            directories: Just(fixture.directory).eraseToAnyPublisher(), indexDirectory: url.deletingLastPathComponent())
        defer { store.stop() }
        let arrived = expectation(description: "nodes")
        var published: [LibraryNode] = []
        let subscription = store.$nodes.first(where: predicate).sink {
            published = $0
            arrived.fulfill()
        }
        store.start()
        let written = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: url.path) }, object: nil)
        await fulfillment(of: [arrived, written], timeout: 10)
        subscription.cancel()
        return published
    }
}
