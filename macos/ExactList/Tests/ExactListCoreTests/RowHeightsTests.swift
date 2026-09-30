import XCTest

@testable import ExactListCore

/// Geometry against a naive reference: `SPEC.md` §5.
///
/// Each method proves the requirement in its name. `SpecCoverageTests` checks
/// that every ID in `SPEC.md` has one.
final class RowHeightsTests: XCTestCase {

    func testG1_prefixSums() throws {
        // Heights and spacing are multiples of 1/4, so every sum is exact in any
        // order and the probes can sit on the boundaries themselves.
        func quarters(_ range: ClosedRange<Int>, _ rng: inout SeededGenerator) -> CGFloat {
            CGFloat(Int.random(in: range, using: &rng)) / 4
        }

        func check(
            _ rows: RowHeights, _ heights: [CGFloat], _ customs: [CGFloat?], _ spacing: CGFloat,
            _ rng: inout SeededGenerator
        )
            -> String?
        {
            let tops = ReferenceGeometry.tops(heights: heights, spacing: spacing, customs: customs)
            let total = ReferenceGeometry.contentHeight(heights: heights, spacing: spacing, customs: customs)
            let bottoms = zip(tops, heights).map { $0 + $1 }
            if rows.count != heights.count { return "count \(rows.count) != \(heights.count)" }
            if rows.values != heights { return "values differ" }
            for row in heights.indices {
                if rows[row] != heights[row] { return "h(\(row)) = \(rows[row]), expected \(heights[row])" }
                if rows.spacing(aboveRow: row) != customs[row] ?? spacing {
                    return "g(\(row)) = \(rows.spacing(aboveRow: row)), expected \(customs[row] ?? spacing)"
                }
                if abs(rows.top(ofRow: row) - tops[row]) > 1e-6 * max(1, total) {
                    return "y(\(row)) = \(rows.top(ofRow: row)), expected \(tops[row])"
                }
            }

            var probes: [CGFloat] = [-1, -0.125, 0, total, total + 0.125, total + 1]
            for row in heights.indices {
                probes += [tops[row], tops[row] + 0.125, bottoms[row] - 0.125, bottoms[row], bottoms[row] + 0.125]
            }
            func containing(_ y: CGFloat) -> Int? {
                heights.indices.first { tops[$0] <= y && y < bottoms[$0] }
            }
            for _ in 0..<12 {
                let y = probes.randomElement(using: &rng)!
                if rows.row(containingY: y) != containing(y) {
                    return "row(containingY: \(y)) = \(String(describing: rows.row(containingY: y)))"
                        + ", expected \(String(describing: containing(y)))"
                }
                let firstBelow = heights.indices.first { bottoms[$0] > y }
                if rows.firstRow(endingBelow: y) != firstBelow {
                    return "firstRow(endingBelow: \(y)) = \(String(describing: rows.firstRow(endingBelow: y)))"
                        + ", expected \(String(describing: firstBelow))"
                }
                // A row that only touches an end of the interval is outside it;
                // a one-point interval is the row containing the point.
                let other = probes.randomElement(using: &rng)!
                let (lower, upper) = Bool.random(using: &rng) ? (min(y, other), max(y, other)) : (y, other)
                let expected: [Int]
                if lower < upper {
                    expected = heights.indices.filter { bottoms[$0] > lower && tops[$0] < upper }
                } else if lower == upper {
                    expected = containing(lower).map { [$0] } ?? []
                } else {
                    expected = []
                }
                if Array(rows.rows(intersecting: lower, upper)) != expected {
                    return "rows(intersecting: \(lower), \(upper)) = \(rows.rows(intersecting: lower, upper))"
                        + ", expected \(expected)"
                }
            }
            return nil
        }

        for index in 0..<10_000 {
            let seed = 0x6100_0000 &+ UInt64(index)
            var rng = SeededGenerator(seed: seed)
            var heights = (0..<Int.random(in: 0...24, using: &rng)).map { _ in quarters(1...400, &rng) }
            var spacing = Bool.random(using: &rng) ? 0 : quarters(0...40, &rng)
            // Half the lists mix custom spacings (G7), zero among them, with the default.
            let mixed = Bool.random(using: &rng)
            func custom() -> CGFloat? {
                guard mixed, Bool.random(using: &rng) else { return nil }
                return Bool.random(using: &rng) ? 0 : quarters(0...80, &rng)
            }
            var customs = heights.map { _ in custom() }
            var rows = RowHeights(heights, customSpacings: customs, spacing: spacing)
            if let failure = check(rows, heights, customs, spacing, &rng) {
                return XCTFail("G1 seed \(seed), as built: \(failure)")
            }
            for _ in 0..<3 where !heights.isEmpty {
                let row = Int.random(in: heights.indices, using: &rng)
                heights[row] = quarters(1...400, &rng)
                rows.setHeight(heights[row], ofRow: row)
                let other = Int.random(in: heights.indices, using: &rng)
                customs[other] = custom()
                rows.setSpacing(customs[other], aboveRow: other)
            }
            spacing = quarters(0...40, &rng)
            rows.spacing = spacing
            if let failure = check(rows, heights, customs, spacing, &rng) {
                return XCTFail("G1 seed \(seed), after setHeight, setSpacing and spacing: \(failure)")
            }
            if rows != RowHeights(heights, customSpacings: customs, spacing: spacing) {
                return XCTFail("G1 seed \(seed): values with the same rows and spacing differ")
            }
        }
    }

    func testG2_exactContentHeight() throws {
        XCTAssertEqual(RowHeights().contentHeight, 0)
        XCTAssertEqual(RowHeights([], spacing: 12).contentHeight, 0, "no rows means no trailing gap")
        XCTAssertEqual(RowHeights([7], spacing: 12).contentHeight, 7)

        for index in 0..<10_000 {
            let seed = 0x6200_0000 &+ UInt64(index)
            var rng = SeededGenerator(seed: seed)
            var heights = (0..<Int.random(in: 0...64, using: &rng)).map { _ in
                CGFloat.random(in: 0.5...800, using: &rng)
            }
            var spacing = Bool.random(using: &rng) ? 0 : CGFloat.random(in: 0...24, using: &rng)
            var rows = RowHeights(heights, spacing: spacing)
            for step in 0..<4 {
                let expected = ReferenceGeometry.contentHeight(heights: heights, spacing: spacing)
                if abs(rows.contentHeight - expected) > 1e-6 * max(1, expected) {
                    return XCTFail("G2 seed \(seed), step \(step): H = \(rows.contentHeight), expected \(expected)")
                }
                if let last = heights.indices.last {
                    let bottom = rows.top(ofRow: last) + rows[last]
                    if abs(bottom - expected) > 1e-6 * max(1, expected) {
                        return XCTFail("G2 seed \(seed), step \(step): the last row ends at \(bottom), not H")
                    }
                }
                if !heights.isEmpty, Bool.random(using: &rng) {
                    let row = Int.random(in: heights.indices, using: &rng)
                    heights[row] = CGFloat.random(in: 0.5...800, using: &rng)
                    rows.setHeight(heights[row], ofRow: row)
                } else {
                    spacing = CGFloat.random(in: 0...24, using: &rng)
                    rows.spacing = spacing
                }
            }
        }
    }

    func testG3_theScrollRange() throws {
        for index in 0..<10_000 {
            let seed = 0x6300_0000 &+ UInt64(index)
            var rng = SeededGenerator(seed: seed)
            let heights = (0..<Int.random(in: 0...40, using: &rng)).map { _ in
                CGFloat.random(in: 1...300, using: &rng)
            }
            let spacing = Bool.random(using: &rng) ? 0 : CGFloat.random(in: 0...16, using: &rng)
            let total = ReferenceGeometry.contentHeight(heights: heights, spacing: spacing)
            let top = Bool.random(using: &rng) ? 0 : CGFloat.random(in: 0...80, using: &rng)
            let bottom = Bool.random(using: &rng) ? 0 : CGFloat.random(in: 0...80, using: &rng)
            let height = CGFloat.random(in: 1...1200, using: &rng)
            let offset = CGFloat.random(in: (-top - 200)...(total + 200), using: &rng)
            let viewport = Viewport(offset: offset, height: height, insetTop: top, insetBottom: bottom)
            let contentHeight = total
            let tolerance = 1e-6 * max(1, total)

            let minimum = -top
            let maximum = max(minimum, total - height + bottom)
            let overscan = (height - top - bottom) / 2
            let failures = [
                viewport.minOffset != minimum ? "oMin = \(viewport.minOffset), expected \(minimum)" : nil,
                abs(viewport.maxOffset(contentHeight: contentHeight) - maximum) > tolerance
                    ? "oMax = \(viewport.maxOffset(contentHeight: contentHeight)), expected \(maximum)" : nil,
                viewport.unobscuredTop != offset + top ? "top of U" : nil,
                viewport.unobscuredBottom != offset + height - bottom ? "bottom of U" : nil,
                viewport.overscan != overscan ? "q" : nil,
                viewport.preparedTop != offset + top - overscan ? "top of P" : nil,
                viewport.preparedBottom != offset + height - bottom + overscan ? "bottom of P" : nil,
            ].compactMap { $0 }
            if let failure = failures.first {
                return XCTFail("G3 seed \(seed): \(failure)")
            }

            let clamped = viewport.clamped(offset, contentHeight: contentHeight)
            let expectedClamp = min(max(offset, minimum), maximum)
            if abs(clamped - expectedClamp) > tolerance
                || clamped < viewport.minOffset
                || clamped > viewport.maxOffset(contentHeight: contentHeight)
            {
                return XCTFail("G3 seed \(seed): clamped(\(offset)) = \(clamped), expected \(expectedClamp)")
            }
            if abs(offset - (maximum - Viewport.tailTolerance)) > tolerance {
                let atTail = offset >= maximum - 1
                if viewport.isAtTail(contentHeight: contentHeight) != atTail {
                    return XCTFail("G3 seed \(seed): isAtTail at o = \(offset), oMax = \(maximum)")
                }
            }
            var landed = viewport
            landed.offset = clamped
            if !landed.isAtTail(contentHeight: contentHeight)
                && clamped == viewport.maxOffset(contentHeight: contentHeight)
            {
                return XCTFail("G3 seed \(seed): oMax is not the tail")
            }
        }
    }

    func testG5_cost() throws {
        // Logarithmic cost grows about 2× from 1k rows to 1M; linear cost grows
        // 1000×, and even √n grows 32×. The bound leaves room for cache effects
        // and noise.
        func seconds(_ body: () -> Void) -> Double {
            var best = Double.infinity
            for _ in 0..<3 {
                let start = DispatchTime.now().uptimeNanoseconds
                body()
                best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
            }
            return best
        }
        func timings(rowCount: Int) -> (top: Double, lookup: Double, set: Double) {
            var rng = SeededGenerator(seed: 0x6500_0000 &+ UInt64(rowCount))
            let heights = (0..<rowCount).map { _ in CGFloat(Int.random(in: 1...400, using: &rng)) }
            var rows = RowHeights(heights, spacing: 2)
            let queries = (0..<20_000).map { _ in Int.random(in: 0..<rowCount, using: &rng) }
            let total = rows.contentHeight
            let ys = queries.map { CGFloat($0) / CGFloat(rowCount) * total }
            var sink: CGFloat = 0
            var found = 0
            let top = seconds { for row in queries { sink += rows.top(ofRow: row) } }
            let lookup = seconds { for y in ys { found &+= rows.firstRow(endingBelow: y) ?? 0 } }
            let set = seconds { for row in queries { rows.setHeight(CGFloat(row % 97 + 1), ofRow: row) } }
            XCTAssertTrue(sink.isFinite && found >= 0)
            return (top, lookup, set)
        }

        let small = timings(rowCount: 1_000)
        let large = timings(rowCount: 1_000_000)
        XCTAssertLessThan(large.top / small.top, 25, "G5: y(i) is not O(log n)")
        XCTAssertLessThan(large.lookup / small.lookup, 25, "G5: y → i is not O(log n)")
        XCTAssertLessThan(large.set / small.set, 25, "G5: a height change is not O(log n)")

        // A batch: its structural calls, and planning its commit, cost what it
        // touches. The same batch, around the middle of 1k rows and of 1M.
        func batchTimings(rowCount: Int) -> (edits: Double, plan: Double) {
            var rng = SeededGenerator(seed: 0x6510_0000 &+ UInt64(rowCount))
            let heights = RowHeights((0..<rowCount).map { _ in CGFloat(Int.random(in: 20...80, using: &rng)) })
            let middle = rowCount / 2
            let edits: [RowEdit] = (0..<100).flatMap { index -> [RowEdit] in
                let at = middle - 50 + index
                return [.insert([at], .effectFade), .remove([at + 1], .effectFade), .noteHeight([at - 20])]
            }
            var map = RowIndexMap(oldCount: rowCount)
            let edit = seconds {
                map = RowIndexMap(oldCount: rowCount)
                for edit in edits { map.apply(edit) }
            }
            let newHeights = heights.applying(map, height: { _ in 44 }, spacing: { _ in nil })
            let top = heights.top(ofRow: middle)
            let viewport = Viewport(offset: top, height: 600, insetTop: 0, insetBottom: 0)
            let mounted = IndexSet(integersIn: heights.rows(intersecting: top - 600, top + 1200))
            var plan: CommitPlan?
            let planning = seconds {
                plan = CommitPlanner.plan(
                    CommitInput(
                        oldHeights: heights, newHeights: newHeights, map: map, oldViewport: viewport,
                        newViewport: viewport, anchoring: .automatic, followsTail: false, rescalesAnchor: false,
                        mountedRows: mounted, animates: true))
            }
            XCTAssertFalse(plan?.motions.isEmpty ?? true, "the batch moves rows in view")
            return (edit, planning)
        }
        let smallBatch = batchTimings(rowCount: 1_000)
        let largeBatch = batchTimings(rowCount: 1_000_000)
        XCTAssertLessThan(largeBatch.edits / smallBatch.edits, 25, "G5: a structural call is not O(e + r)")
        XCTAssertLessThan(largeBatch.plan / smallBatch.plan, 25, "G5: planning is not O((e + k + m) · log n)")
    }

    func testG7_theSpacingAboveARow() throws {
        // Row 0's spacing is its own and takes no space while it is first.
        var rows = RowHeights([10, 20], customSpacings: [5, nil], spacing: 3)
        XCTAssertEqual(rows.top(ofRow: 1), 13)
        XCTAssertEqual(rows.contentHeight, 33)
        rows.setSpacing(40, aboveRow: 0)
        XCTAssertEqual(rows.contentHeight, 33, "row 0's spacing took space")
        XCTAssertEqual(rows.spacing(aboveRow: 0), 40)
        // …and holds once a row arrives above it.
        var map = RowIndexMap(oldCount: 2)
        map.apply(.insert([0], []))
        let grown = rows.applying(map, height: { _ in 7 }, spacing: { _ in nil })
        XCTAssertEqual(grown.top(ofRow: 1), 47, "the old first row starts its own spacing below the new one")
        XCTAssertEqual(grown.contentHeight, 33 + 7 + 40)

        // A change of the default moves only the rows on it (V3).
        var mixed = RowHeights([10, 10, 10, 10], customSpacings: [nil, 0, nil, 6], spacing: 2)
        XCTAssertEqual((0..<4).map { mixed.top(ofRow: $0) }, [0, 10, 22, 38])
        mixed.spacing = 14
        XCTAssertEqual((0..<4).map { mixed.top(ofRow: $0) }, [0, 10, 34, 50])

        // A gap belongs to no row, even between rows that are flush elsewhere.
        XCTAssertEqual(mixed.row(containingY: 10), 1, "a flush row starts where the one above ends")
        XCTAssertNil(mixed.row(containingY: 25), "a point in a gap is no row's (G4)")
        XCTAssertEqual(Array(mixed.rows(intersecting: 15, 34)), [1], "a row only touching the end is outside")
    }

    func testG6_tolerance() throws {
        // Heights over six orders of magnitude, and many height changes on the
        // same value, against a fresh left-to-right sum.
        for index in 0..<20 {
            let seed = 0x6600_0000 &+ UInt64(index)
            var rng = SeededGenerator(seed: seed)
            func height() -> CGFloat { pow(10, CGFloat.random(in: -2...4, using: &rng)) }
            var heights = (0..<Int.random(in: 1...600, using: &rng)).map { _ in height() }
            let spacing = CGFloat.random(in: 0...10, using: &rng)
            var rows = RowHeights(heights, spacing: spacing)
            for update in 0..<1_000 {
                let row = Int.random(in: heights.indices, using: &rng)
                heights[row] = height()
                rows.setHeight(heights[row], ofRow: row)
                guard update % 100 == 99 else { continue }
                let tops = ReferenceGeometry.tops(heights: heights, spacing: spacing)
                let total = ReferenceGeometry.contentHeight(heights: heights, spacing: spacing)
                let tolerance = 1e-6 * max(1, total)
                if abs(rows.contentHeight - total) > tolerance {
                    return XCTFail("G6 seed \(seed), update \(update): H = \(rows.contentHeight), expected \(total)")
                }
                for row in heights.indices where abs(rows.top(ofRow: row) - tops[row]) > tolerance {
                    return XCTFail(
                        "G6 seed \(seed), update \(update): y(\(row)) = \(rows.top(ofRow: row)), expected \(tops[row])")
                }
                for row in heights.indices {
                    let middle = tops[row] + heights[row] / 2
                    if heights[row] > 2 * tolerance, rows.row(containingY: middle) != row {
                        return XCTFail("G6 seed \(seed), update \(update): row(containingY: \(middle)) is not \(row)")
                    }
                }
            }
        }
    }
}
