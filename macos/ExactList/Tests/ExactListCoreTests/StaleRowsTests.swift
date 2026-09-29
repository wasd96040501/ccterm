import XCTest

@testable import ExactListCore

/// Stale bookkeeping and refresh order: §9.
///
/// Each method proves the requirement in its name. `SpecCoverageTests` checks
/// that every ID in `SPEC.md` has one.
final class StaleRowsTests: XCTestCase {

    func testW5_staleRowsAreRefreshed() throws {
        // The reference: one flag per row, and the order written as a sort by
        // distance from the anchor, the row below first on a tie.
        func order(_ flags: [Bool], around anchor: Int, limit: Int) -> [Int] {
            let rows = flags.indices.filter { flags[$0] }.sorted {
                (abs($0 - anchor), $0 < anchor ? 1 : 0) < (abs($1 - anchor), $1 < anchor ? 1 : 0)
            }
            return Array(rows.prefix(max(0, limit)))
        }
        func check(_ stale: StaleRows, _ flags: [Bool], _ rng: inout SeededGenerator) -> String? {
            for row in -1...flags.count where stale.contains(row) != (flags.indices.contains(row) && flags[row]) {
                return "contains(\(row)) = \(stale.contains(row))"
            }
            if stale.isEmpty != !flags.contains(true) { return "isEmpty = \(stale.isEmpty)" }
            let anchors = [0, flags.count - 1, Int.random(in: -2...(flags.count + 1), using: &rng)]
            for anchor in anchors {
                let limit = Int.random(in: 0...(flags.count + 2), using: &rng)
                let expected = order(flags, around: anchor, limit: limit)
                if stale.refreshOrder(around: anchor, limit: limit) != expected {
                    return "refreshOrder(around: \(anchor), limit: \(limit)) = "
                        + "\(stale.refreshOrder(around: anchor, limit: limit)), expected \(expected)"
                }
            }
            return nil
        }

        let hand = {
            var stale = StaleRows(count: 7)
            stale.markAllStale(except: [3])
            return stale.refreshOrder(around: 3, limit: 10)
        }()
        XCTAssertEqual(hand, [4, 2, 5, 1, 6, 0], "W5: outward from the anchor, down first")

        for index in 0..<10_000 {
            let seed = 0x0500_0000 &+ UInt64(index)
            var rng = SeededGenerator(seed: seed)
            func subset(of count: Int) -> IndexSet {
                IndexSet((0..<count).filter { _ in Int.random(in: 0..<4, using: &rng) == 0 })
            }
            var flags = [Bool](repeating: false, count: Int.random(in: 0...60, using: &rng))
            var stale = StaleRows(count: flags.count)
            if let failure = check(stale, flags, &rng) { return XCTFail("W5 seed \(seed), new: \(failure)") }

            for step in 0..<Int.random(in: 1...6, using: &rng) {
                switch Int.random(in: 0..<3, using: &rng) {
                case 0:
                    let fresh = subset(of: flags.count)
                    stale.markAllStale(except: fresh)
                    flags = flags.indices.map { !fresh.contains($0) }
                case 1:
                    let fresh = subset(of: flags.count)
                    stale.markFresh(fresh)
                    for row in fresh { flags[row] = false }
                default:
                    var count = flags.count
                    var edits: [RowEdit] = []
                    for _ in 0..<Int.random(in: 1...4, using: &rng) {
                        switch Int.random(in: 0..<4, using: &rng) {
                        case 0:
                            let size = Int.random(in: 1...3, using: &rng)
                            let rows = IndexSet(Array(0..<(count + size)).shuffled(using: &rng).prefix(size))
                            edits.append(.insert(rows, []))
                            count += size
                        case 1 where count > 0:
                            let size = Int.random(in: 1...min(3, count), using: &rng)
                            edits.append(.remove(IndexSet(Array(0..<count).shuffled(using: &rng).prefix(size)), []))
                            count -= size
                        case 2 where count > 0:
                            let from = Int.random(in: 0..<count, using: &rng)
                            edits.append(.move(from: from, to: Int.random(in: 0..<count, using: &rng)))
                        default:
                            edits.append(.noteHeight(subset(of: count)))
                        }
                    }
                    var map = RowIndexMap(oldCount: flags.count)
                    for edit in edits { map.apply(edit) }
                    stale.apply(map)
                    let before = flags
                    flags = ReferenceGeometry.replay(oldCount: flags.count, edits: edits).map { old in
                        old.map { before[$0] } ?? false
                    }
                }
                if let failure = check(stale, flags, &rng) {
                    return XCTFail("W5 seed \(seed), step \(step): \(failure)")
                }
            }

            // Refreshing a few rows per turn, as the refresher does, ends.
            let perTurn = Int.random(in: 1...5, using: &rng)
            let staleCount = flags.filter { $0 }.count
            var turns = 0
            while !stale.isEmpty {
                let rows = stale.refreshOrder(around: Int.random(in: 0...flags.count, using: &rng), limit: perTurn)
                if rows.isEmpty { return XCTFail("W5 seed \(seed): a turn with stale rows refreshed none") }
                stale.markFresh(IndexSet(rows))
                turns += 1
                if turns > staleCount { return XCTFail("W5 seed \(seed): refreshing doesn't end") }
            }
        }
    }
}
