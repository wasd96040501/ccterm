import Foundation

/// Pure tree-building for the sidebar's `NSOutlineView`. Extracted from
/// `SidebarViewController` so grouping / ordering / new-folder detection
/// are unit-testable without mounting the controller.
///
/// Everything here is a side-effect-free function of its inputs: no
/// `UserDefaults`, no `SidebarSessionGroupOrderStore`, no view controller.
/// The caller snapshots the store's `storedOrder()` and passes it in as
/// `groupOrder`; the previously-seen group set (the controller's
/// `lastSeenGroups`) is passed in as `previouslySeenGroups` and the
/// freshly-detected new groups come back out as `newGroups`. Making that
/// previously-hidden mutable cache an explicit in/out parameter is what
/// keeps invariant 6.10 (groups already present at launch are not treated
/// as newly-appeared) honest and testable.
///
/// The nodes are `SidebarItemNode` (a reference type, invariant 6.1):
/// `NSOutlineView` keys row reuse on `===`, so identity has to survive a
/// `reloadData()`. `build` produces fresh node instances each call; the
/// controller feeds them to the same `reloadData()` it always used (no
/// fine-grained diff — DNT-8).
enum SidebarTreeModel {

    /// Folder grouping bucket used internally while assembling nodes.
    private struct RecordGroup {
        let folderName: String
        let records: [SessionRecord]
    }

    /// Build the root children for the outline plus the set of group
    /// folders that appeared since `previouslySeenGroups`.
    ///
    /// - Parameters:
    ///   - records: the session repository's current records.
    ///   - groupOrder: snapshot of the order store's `storedOrder()` — the
    ///     persisted relative ordering of group folders. Treated as a pure
    ///     input; this function never reads or writes UserDefaults.
    ///   - previouslySeenGroups: the group set from the last refresh (the
    ///     controller's `lastSeenGroups`). Folders already in this set are
    ///     excluded from `newGroups`, so cold-start (seeded in
    ///     `viewDidLoad`) doesn't treat existing folders as new.
    /// - Returns: `nodes` — `FixedKind.allCases` fixed rows followed by
    ///   folder rows (each holding its history children); `newGroups` —
    ///   group folders present now but not in `previouslySeenGroups`.
    static func build(
        records: [SessionRecord],
        groupOrder: [String],
        previouslySeenGroups: Set<String>
    ) -> (nodes: [SidebarItemNode], newGroups: [String]) {
        let nodes = buildRootChildren(records: records, groupOrder: groupOrder)
        let new = currentGroupSet(records).subtracting(previouslySeenGroups)
        // The live VC iterated an unordered `Set` here, so the order in
        // which multiple simultaneously-new groups were prepended was
        // nondeterministic. Sort for a deterministic output; see this
        // PR's notes — `prependIfAbsent` is insensitive to ordering for a
        // single new group, and this tightening only affects the relative
        // slot of several groups appearing in the same refresh.
        let newGroups = new.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return (nodes, newGroups)
    }

    /// Group folders currently present in `records`, by
    /// `groupingFolderName`. **Skips records whose `groupingFolderName` is
    /// `nil`** — this is deliberately asymmetric with `buildRootChildren`,
    /// which folds nil into an "Unknown" folder node. New-folder detection
    /// only ever fires for records that carry a real folder name; the
    /// "Unknown" bucket never counts as a newly-appeared group. Preserved
    /// verbatim from the controller's old `currentGroupSet()`.
    static func currentGroupSet(_ records: [SessionRecord]) -> Set<String> {
        var s: Set<String> = []
        for record in records {
            if let name = record.groupingFolderName {
                s.insert(name)
            }
        }
        return s
    }

    // MARK: - Node assembly

    private static func buildRootChildren(
        records: [SessionRecord],
        groupOrder: [String]
    ) -> [SidebarItemNode] {
        var items: [SidebarItemNode] = []
        for kind in FixedKind.allCases {
            items.append(
                SidebarItemNode(kind: .fixed(kind), selection: kind.selection))
        }
        for group in groupedRecords(records: records, groupOrder: groupOrder) {
            let children = group.records.map { record in
                SidebarItemNode(
                    kind: .history(
                        sessionId: record.sessionId,
                        fallbackTitle: record.title,
                        isDraft: record.status == .draft),
                    selection: .session(record.sessionId))
            }
            items.append(
                SidebarItemNode(
                    kind: .folder(name: group.folderName),
                    selection: nil,
                    children: children))
        }
        return items
    }

    private static func groupedRecords(
        records: [SessionRecord],
        groupOrder: [String]
    ) -> [RecordGroup] {
        // `/new` / `/clear` drafts are ordinary `.draft`-status rows in
        // `records` now, so they group + sort like any other history row
        // (their fresh `lastActiveAt` floats them to the top of the folder).
        // nil `groupingFolderName` folds into an "Unknown" folder — note
        // this is asymmetric with `currentGroupSet`, which skips nil.
        let buckets = Dictionary(grouping: records) {
            $0.groupingFolderName ?? "Unknown"
        }
        let folderNames = Array(buckets.keys)
        let ordered = arrange(folderNames, storedOrder: groupOrder)
        return ordered.compactMap { name -> RecordGroup? in
            guard let records = buckets[name] else { return nil }
            return RecordGroup(
                folderName: name,
                records: records.sorted { $0.lastActiveAt > $1.lastActiveAt })
        }
    }

    /// Order `groups` for display: names present in `storedOrder` keep their
    /// stored relative position; everything else is appended sorted by
    /// `localizedStandardCompare` (case-insensitive, numeric-aware). This is
    /// the inlined, pure form of `SidebarSessionGroupOrderStore.arrange`,
    /// with the persisted order handed in rather than read from UserDefaults.
    private static func arrange(_ groups: [String], storedOrder: [String]) -> [String] {
        let presentSet = Set(groups)
        let knownInOrder = storedOrder.filter { presentSet.contains($0) }
        let knownSet = Set(knownInOrder)
        let unknown =
            groups
            .filter { !knownSet.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return knownInOrder + unknown
    }
}
