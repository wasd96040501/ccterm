import XCTest

@testable import ExactListCore

/// NSTableView's incremental index rules against a naive array replay: §7.
///
/// Each method proves the requirement in its name. `SpecCoverageTests` checks
/// that every ID in `SPEC.md` has one.
final class RowIndexMapTests: XCTestCase {

    func testU2_nsTableViewsIndexSemantics() throws {
        // The reference itself, on cases worked by hand from NSTableView's docs.
        XCTAssertEqual(ReferenceGeometry.replay(oldCount: 2, edits: [.insert([0, 2], [])]), [nil, 0, nil, 1])
        XCTAssertEqual(ReferenceGeometry.replay(oldCount: 5, edits: [.remove([1, 3], [])]), [0, 2, 4])
        XCTAssertEqual(ReferenceGeometry.replay(oldCount: 4, edits: [.move(from: 0, to: 2)]), [1, 2, 0, 3])
        XCTAssertEqual(
            ReferenceGeometry.replay(oldCount: 3, edits: [.insert([0], []), .remove([1], [])]), [nil, 1, 2])

        // A row's flags and transitions, tracked the naive way beside the replay.
        struct Row: Equatable {
            var old: Int?
            var transition: RowTransition = []
            var moved = false
            var noted = false
            var reloaded = false
        }
        struct Model {
            var rows: [Row]
            var removals: [Int: RowTransition] = [:]
            init(oldCount: Int) { rows = (0..<oldCount).map { Row(old: $0) } }
            mutating func apply(_ edit: RowEdit) {
                switch edit {
                case .insert(let indexes, let transition):
                    for index in indexes { rows.insert(Row(old: nil, transition: transition), at: index) }
                case .remove(let indexes, let transition):
                    for index in indexes.reversed() {
                        if let old = rows.remove(at: index).old { removals[old] = transition }
                    }
                case .move(let from, let to):
                    var row = rows.remove(at: from)
                    row.moved = row.old != nil
                    rows.insert(row, at: to)
                case .noteHeight(let indexes):
                    for index in indexes where rows[index].old != nil { rows[index].noted = true }
                case .reload(let indexes):
                    for index in indexes where rows[index].old != nil { rows[index].reloaded = true }
                }
            }
            func indexes(_ flag: (Row) -> Bool) -> IndexSet { IndexSet(rows.indices.filter { flag(rows[$0]) }) }
        }

        func check(oldCount: Int, edits: [RowEdit]) -> String? {
            var map = RowIndexMap(oldCount: oldCount)
            var model = Model(oldCount: oldCount)
            for edit in edits {
                map.apply(edit)
                model.apply(edit)
            }
            let replayed = ReferenceGeometry.replay(oldCount: oldCount, edits: edits)
            if model.rows.map(\.old) != replayed { return "the two references disagree" }
            if map.oldCount != oldCount { return "oldCount \(map.oldCount)" }
            if map.newCount != replayed.count { return "newCount \(map.newCount), expected \(replayed.count)" }
            for row in replayed.indices where map.oldIndex(forNew: row) != replayed[row] {
                return "oldIndex(forNew: \(row)) = \(String(describing: map.oldIndex(forNew: row)))"
                    + ", expected \(String(describing: replayed[row]))"
            }
            for old in 0..<oldCount where map.newIndex(forOld: old) != replayed.firstIndex(of: old) {
                return "newIndex(forOld: \(old)) = \(String(describing: map.newIndex(forOld: old)))"
                    + ", expected \(String(describing: replayed.firstIndex(of: old)))"
            }
            var insertions: [Int: RowTransition] = [:]
            for (row, entry) in model.rows.enumerated() where entry.old == nil { insertions[row] = entry.transition }
            if map.insertions != insertions { return "insertions \(map.insertions), expected \(insertions)" }
            if Set(map.insertions.keys) != Set(replayed.indices.filter { replayed[$0] == nil }) {
                return "insertions aren't the replay's new rows"
            }
            if map.removals != model.removals { return "removals \(map.removals), expected \(model.removals)" }
            if Set(map.removals.keys) != Set((0..<oldCount).filter { !replayed.contains($0) }) {
                return "removals aren't the replay's missing rows"
            }
            if map.movedRows != model.indexes(\.moved) { return "movedRows \(Array(map.movedRows))" }
            if map.notedRows != model.indexes(\.noted) { return "notedRows \(Array(map.notedRows))" }
            if map.reloadedRows != model.indexes(\.reloaded) { return "reloadedRows \(Array(map.reloadedRows))" }
            if map.isEmpty != edits.isEmpty { return "isEmpty \(map.isEmpty) after \(edits.count) edits" }

            // The runs (G5) tile the new rows in order, and say what the model says.
            var next = 0
            for run in map.runs {
                if run.newStart != next || run.count < 1 { return "runs \(map.runs) don't tile the rows" }
                for row in run.newStart..<(run.newStart + run.count) {
                    let entry = model.rows[row]
                    switch run {
                    case .kept(let old, let new, _):
                        if entry.old != old + (row - new) || entry.moved { return "runs: \(run) at row \(row)" }
                    case .moved(let old, _):
                        if entry.old != old || !entry.moved { return "runs: \(run) at row \(row)" }
                    case .inserted(_, _, let transition):
                        if entry.old != nil || entry.transition != transition { return "runs: \(run) at row \(row)" }
                    }
                }
                next += run.count
            }
            if next != model.rows.count { return "runs cover \(next) rows of \(model.rows.count)" }
            let structural = model.rows.map(\.old) != Array(0..<oldCount) || model.rows.contains(where: \.moved)
            if map.isStructural != structural { return "isStructural \(map.isStructural)" }

            // The rows after the batch: kept unless noted; the rest asked in
            // order, height then spacing (G7). The old rows mix custom
            // spacings with the default, and so do the answers.
            func oldSpacing(_ row: Int) -> CGFloat? { row % 3 == 0 ? nil : CGFloat(row % 3) / 4 }
            func newSpacing(_ row: Int) -> CGFloat? { row % 2 == 0 ? nil : 0 }
            let before = RowHeights(
                (0..<oldCount).map { CGFloat($0 + 1) }, customSpacings: (0..<oldCount).map(oldSpacing), spacing: 1)
            var asked: [String] = []
            let after = before.applying(
                map,
                height: { row in
                    asked.append("h\(row)")
                    return CGFloat(1000 + row)
                },
                spacing: { row in
                    asked.append("g\(row)")
                    return newSpacing(row)
                })
            let expectedAsked = model.rows.indices.filter { model.rows[$0].old == nil || model.rows[$0].noted }
            if asked != expectedAsked.flatMap({ ["h\($0)", "g\($0)"] }) {
                return "applying asked \(asked), expected \(expectedAsked), each height then spacing"
            }
            let expectedHeights = model.rows.enumerated().map { row, entry in
                entry.old.map { entry.noted ? CGFloat(1000 + row) : CGFloat($0 + 1) } ?? CGFloat(1000 + row)
            }
            let expectedSpacings = model.rows.enumerated().map { row, entry in
                (entry.old.map { entry.noted ? newSpacing(row) : oldSpacing($0) } ?? newSpacing(row)) ?? 1
            }
            if after.values != expectedHeights || after.spacing != 1 { return "applying gave \(after.values)" }
            for row in expectedSpacings.indices where after.spacing(aboveRow: row) != expectedSpacings[row] {
                return "applying: spacing above row \(row) is \(after.spacing(aboveRow: row))"
            }
            // Its geometry is the new rows' own, however much of the old index
            // it kept: every top against a running sum.
            var bottom: CGFloat = 0
            for row in expectedHeights.indices {
                let top = row == 0 ? 0 : bottom + expectedSpacings[row]
                if after.top(ofRow: row) != top { return "applying: top of row \(row) is \(after.top(ofRow: row))" }
                bottom = top + expectedHeights[row]
            }
            if after.contentHeight != bottom { return "applying: content height \(after.contentHeight)" }
            return nil
        }

        // Cases worked by hand, then random batches.
        let handWorked: [(Int, [RowEdit])] = [
            (2, [.insert([1], []), .remove([1], [])]),  // inserted, then removed: in neither
            (3, [.move(from: 0, to: 2), .remove([2], .effectFade)]),  // moved, then removed: removed only
            (2, [.insert([0], .slideUp), .move(from: 0, to: 2)]),  // an inserted row that moves stays inserted
            (3, [.noteHeight([0]), .reload([0]), .move(from: 0, to: 2)]),  // the flags follow the row
            (3, [.noteHeight([1]), .remove([1], [])]),  // a noted row that goes drops out
            (2, [.insert([0], []), .noteHeight([0]), .reload([0])]),  // inserted rows are never noted
            (3, [.move(from: 1, to: 1)]),
            (0, [.insert([0, 1, 2], .effectGap)]),
            (4, [.remove([0, 1, 2, 3], .slideLeft)]),
            (4, []),
        ]
        for (index, (oldCount, edits)) in handWorked.enumerated() {
            if let failure = check(oldCount: oldCount, edits: edits) {
                return XCTFail("U2 hand-worked case \(index): \(failure)")
            }
        }

        let transitions: [RowTransition] = [
            [], .effectFade, .effectGap, .slideUp, .slideDown, [.effectFade, .slideRight],
        ]
        for index in 0..<10_000 {
            let seed = 0x0200_0000 &+ UInt64(index)
            var rng = SeededGenerator(seed: seed)
            func subset(of count: Int, size: Int) -> IndexSet {
                IndexSet(Array(0..<count).shuffled(using: &rng).prefix(size))
            }
            let oldCount = Int.random(in: 0...30, using: &rng)
            var count = oldCount
            var edits: [RowEdit] = []
            for _ in 0..<Int.random(in: 0...8, using: &rng) {
                let transition = transitions.randomElement(using: &rng)!
                switch Int.random(in: 0..<5, using: &rng) {
                case 0:
                    let size = Int.random(in: 0...4, using: &rng)
                    edits.append(.insert(subset(of: count + size, size: size), transition))
                    count += size
                case 1 where count > 0:
                    let size = Int.random(in: 1...min(4, count), using: &rng)
                    edits.append(.remove(subset(of: count, size: size), transition))
                    count -= size
                case 2 where count > 0:
                    let from = Int.random(in: 0..<count, using: &rng)
                    edits.append(.move(from: from, to: Int.random(in: 0..<count, using: &rng)))
                case 3:
                    edits.append(.noteHeight(subset(of: count, size: Int.random(in: 0...min(3, count), using: &rng))))
                default:
                    edits.append(.reload(subset(of: count, size: Int.random(in: 0...min(3, count), using: &rng))))
                }
            }
            if let failure = check(oldCount: oldCount, edits: edits) {
                return XCTFail("U2 seed \(seed), \(oldCount) rows, edits \(edits): \(failure)")
            }
        }
    }
}
