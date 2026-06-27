import XCTest

@testable import ccterm

/// Pure-logic tests for `SidebarTreeModel.build` / `.currentGroupSet`.
/// No VC mount, no UserDefaults, no `.shared` — `build` is a pure
/// function of (records, groupOrder, previouslySeenGroups), so the test
/// constructs `SessionRecord` values directly and asserts on the returned
/// nodes / newGroups.
@MainActor
final class SidebarTreeModelTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Fixtures

    private func record(
        sessionId: String = UUID().uuidString.lowercased(),
        title: String = "Untitled",
        originPath: String?,
        cwd: String? = nil,
        lastActiveAt: Date = Date(),
        status: SessionStatus = .created,
        isTempDir: Bool = false
    ) -> SessionRecord {
        SessionRecord(
            sessionId: sessionId,
            title: title,
            cwd: cwd ?? originPath,
            originPath: originPath,
            lastActiveAt: lastActiveAt,
            status: status,
            isTempDir: isTempDir)
    }

    /// The folder nodes from a `build` result, in order. Fixed rows always
    /// come first (`FixedKind.allCases`); folders follow.
    private func folderNodes(_ nodes: [SidebarItemNode]) -> [SidebarItemNode] {
        Array(nodes.dropFirst(FixedKind.allCases.count))
    }

    // MARK: - Fixed rows lead

    func testFixedRowsLeadInOrder() {
        let result = SidebarTreeModel.build(
            records: [], groupOrder: [], previouslySeenGroups: [])

        XCTAssertEqual(result.nodes.count, FixedKind.allCases.count)
        for (index, kind) in FixedKind.allCases.enumerated() {
            guard case .fixed = result.nodes[index].kind else {
                return XCTFail("expected fixed node at \(index)")
            }
            // FixedKind isn't Equatable; compare via its selection, which is.
            XCTAssertEqual(result.nodes[index].selection, kind.selection)
        }
        XCTAssertTrue(result.newGroups.isEmpty)
    }

    // MARK: - Grouping

    func testRecordsGroupByFolderName() {
        let a = record(originPath: "/Users/me/work/project-a")
        let b = record(originPath: "/Users/me/work/project-b")
        let a2 = record(originPath: "/Users/me/work/project-a")

        let result = SidebarTreeModel.build(
            records: [a, b, a2], groupOrder: [], previouslySeenGroups: [])

        let folders = folderNodes(result.nodes)
        XCTAssertEqual(Set(folders.compactMap(\.folderName)), ["project-a", "project-b"])
        // project-a holds two history children, project-b one.
        let byName = Dictionary(uniqueKeysWithValues: folders.map { ($0.folderName!, $0) })
        XCTAssertEqual(byName["project-a"]?.children.count, 2)
        XCTAssertEqual(byName["project-b"]?.children.count, 1)
    }

    func testNilGroupingFolderFoldsIntoUnknownNode() {
        // originPath nil + cwd nil → groupingFolderName == nil → "Unknown".
        let homeless = record(originPath: nil, cwd: nil)
        let named = record(originPath: "/Users/me/work/project-a")

        let result = SidebarTreeModel.build(
            records: [homeless, named], groupOrder: [], previouslySeenGroups: [])

        let folders = folderNodes(result.nodes)
        XCTAssertTrue(folders.contains { $0.folderName == "Unknown" })
        XCTAssertTrue(folders.contains { $0.folderName == "project-a" })
    }

    func testTempDirGroupsUnderTempLabel() {
        let temp = record(originPath: nil, cwd: "/tmp/scratch", isTempDir: true)

        let result = SidebarTreeModel.build(
            records: [temp], groupOrder: [], previouslySeenGroups: [])

        let folders = folderNodes(result.nodes)
        XCTAssertEqual(folders.compactMap(\.folderName), ["临时会话"])
    }

    // MARK: - Recency sort within a group

    func testHistoryRowsSortByLastActiveDescending() {
        let now = Date()
        let oldest = record(
            sessionId: "oldest", originPath: "/p", lastActiveAt: now.addingTimeInterval(-100))
        let newest = record(
            sessionId: "newest", originPath: "/p", lastActiveAt: now)
        let middle = record(
            sessionId: "middle", originPath: "/p", lastActiveAt: now.addingTimeInterval(-50))

        let result = SidebarTreeModel.build(
            records: [oldest, newest, middle], groupOrder: [], previouslySeenGroups: [])

        let folder = try? XCTUnwrap(folderNodes(result.nodes).first)
        let ids: [String] =
            folder?.children.compactMap {
                if case .history(let sessionId, _, _) = $0.kind { return sessionId }
                return nil
            } ?? []
        XCTAssertEqual(ids, ["newest", "middle", "oldest"])
    }

    // MARK: - Group order (inlined arrange)

    func testStoredOrderLeadsThenUnknownAlphabetical() {
        // Present folders: alpha, beta, gamma, delta. Stored order pins
        // gamma then alpha; beta + delta are unknown → appended sorted
        // ascending by localizedStandardCompare (beta before delta).
        let recs = [
            record(originPath: "/x/alpha"),
            record(originPath: "/x/beta"),
            record(originPath: "/x/gamma"),
            record(originPath: "/x/delta"),
        ]
        let result = SidebarTreeModel.build(
            records: recs, groupOrder: ["gamma", "alpha"], previouslySeenGroups: [])

        XCTAssertEqual(
            folderNodes(result.nodes).compactMap(\.folderName),
            ["gamma", "alpha", "beta", "delta"])
    }

    func testStoredOrderIgnoresStaleEntries() {
        // A stored name no longer present is filtered out of the order.
        let recs = [record(originPath: "/x/alpha")]
        let result = SidebarTreeModel.build(
            records: recs, groupOrder: ["ghost", "alpha"], previouslySeenGroups: [])

        XCTAssertEqual(folderNodes(result.nodes).compactMap(\.folderName), ["alpha"])
    }

    // MARK: - New-folder detection (inv 6.10)

    func testPreviouslySeenGroupsExcludedFromNewGroups() {
        let recs = [
            record(originPath: "/x/seen"),
            record(originPath: "/x/fresh"),
        ]
        let result = SidebarTreeModel.build(
            records: recs, groupOrder: [], previouslySeenGroups: ["seen"])

        XCTAssertEqual(result.newGroups, ["fresh"])
    }

    func testAllSeenYieldsNoNewGroups() {
        let recs = [record(originPath: "/x/alpha"), record(originPath: "/x/beta")]
        let result = SidebarTreeModel.build(
            records: recs, groupOrder: [], previouslySeenGroups: ["alpha", "beta"])

        XCTAssertTrue(result.newGroups.isEmpty)
    }

    func testMultipleNewGroupsAreSortedDeterministically() {
        let recs = [
            record(originPath: "/x/charlie"),
            record(originPath: "/x/alpha"),
            record(originPath: "/x/bravo"),
        ]
        let result = SidebarTreeModel.build(
            records: recs, groupOrder: [], previouslySeenGroups: [])

        XCTAssertEqual(result.newGroups, ["alpha", "bravo", "charlie"])
    }

    func testNilGroupRecordNeverCountsAsNewGroupButStillBuildsUnknownNode() {
        // nil-skip asymmetry: a record with nil groupingFolderName produces
        // an "Unknown" folder node but is NOT reported as a new group.
        let homeless = record(originPath: nil, cwd: nil)
        let result = SidebarTreeModel.build(
            records: [homeless], groupOrder: [], previouslySeenGroups: [])

        XCTAssertTrue(result.newGroups.isEmpty)
        XCTAssertTrue(folderNodes(result.nodes).contains { $0.folderName == "Unknown" })

        // And the same nil-skip via the standalone helper.
        XCTAssertTrue(SidebarTreeModel.currentGroupSet([homeless]).isEmpty)
    }

    func testCurrentGroupSetCollectsNonNilNames() {
        let recs = [
            record(originPath: "/x/alpha"),
            record(originPath: nil, cwd: nil),
            record(originPath: "/x/beta"),
            record(originPath: "/x/alpha"),
        ]
        XCTAssertEqual(SidebarTreeModel.currentGroupSet(recs), ["alpha", "beta"])
    }

    // MARK: - History node snapshot fields

    func testHistoryNodeSnapshotsDraftAndTitle() {
        let draft = record(
            sessionId: "draft-id", title: "", originPath: "/x/proj", status: .draft)
        let normal = record(
            sessionId: "normal-id", title: "Real", originPath: "/x/proj", status: .created)

        let result = SidebarTreeModel.build(
            records: [draft, normal], groupOrder: [], previouslySeenGroups: [])

        let children = try? XCTUnwrap(folderNodes(result.nodes).first?.children)
        let byId = Dictionary(
            uniqueKeysWithValues: (children ?? []).compactMap { node -> (String, SidebarItemNode.Kind)? in
                if case .history(let sessionId, _, _) = node.kind { return (sessionId, node.kind) }
                return nil
            })

        if case .history(_, let fallback, let isDraft) = byId["draft-id"] {
            XCTAssertEqual(fallback, "")
            XCTAssertTrue(isDraft)
        } else {
            XCTFail("missing draft history node")
        }
        if case .history(_, let fallback, let isDraft) = byId["normal-id"] {
            XCTAssertEqual(fallback, "Real")
            XCTAssertFalse(isDraft)
        } else {
            XCTFail("missing normal history node")
        }

        // History node carries the session selection.
        let normalNode = children?.first { $0.selection == .session("normal-id") }
        XCTAssertNotNil(normalNode)
    }

    // MARK: - Reference identity (inv 6.1)

    func testNodesAreReferenceTypeWithDistinctIdentities() {
        let recs = [record(originPath: "/x/alpha"), record(originPath: "/x/beta")]
        let result = SidebarTreeModel.build(
            records: recs, groupOrder: [], previouslySeenGroups: [])

        let folders = folderNodes(result.nodes)
        // SidebarItemNode is a class: distinct folder nodes are distinct
        // instances (===-identity is what NSOutlineView keys row reuse on).
        XCTAssertFalse(folders[0] === folders[1])
        // A node is identical to itself by reference.
        XCTAssertTrue(folders[0] === folders[0])
        // Each build produces fresh instances (no caching/sharing).
        let again = SidebarTreeModel.build(
            records: recs, groupOrder: [], previouslySeenGroups: [])
        XCTAssertFalse(folderNodes(again.nodes)[0] === folders[0])
    }
}
