import XCTest

@testable import ExactListCore

/// Anchor resolution, renumbering and restoring against the reference: §6.
///
/// Each method proves the requirement in its name. `SpecCoverageTests` checks
/// that every ID in `SPEC.md` has one.
final class ScrollAnchorTests: XCTestCase {

    func testA1_automatic() throws {
        var seen: [String: Int] = [:]
        for index in 0..<10_000 {
            let seed = 0xA100_0000 &+ UInt64(index)
            var rng = SeededGenerator(seed: seed)
            let state = AnchorState.random(&rng, elastic: true)
            let followsTail = Bool.random(using: &rng)
            let expected = state.resolve(.automatic, followsTail: followsTail)
            let actual = ScrollAnchor.resolve(
                .automatic, heights: state.rowHeights, viewport: state.viewport, followsTail: followsTail)
            if let failure = anchorMismatch(actual, expected, tolerance: state.tolerance) {
                return XCTFail("A1 seed \(seed), \(state), followsTail \(followsTail): \(failure)")
            }
            seen[kindName(expected), default: 0] += 1
            if case .row(_, let distance) = expected, distance < 0 { seen["row above U", default: 0] += 1 }
            if case .row(_, let distance) = expected, distance == 0 { seen["row at U", default: 0] += 1 }
        }
        // The generator reaches every branch of A1, the boundary probes included.
        for kind in ["tail", "row", "offset", "row above U", "row at U"] {
            XCTAssertGreaterThan(seen[kind, default: 0], 200, "A1 generator rarely reaches \(kind): \(seen)")
        }
    }

    func testA2_rowR() throws {
        var atTailFollowing = 0
        for index in 0..<10_000 {
            let seed = 0xA200_0000 &+ UInt64(index)
            var rng = SeededGenerator(seed: seed)
            let state = AnchorState.random(&rng, elastic: true, minimumCount: 1)
            let followsTail = Int.random(in: 0..<4, using: &rng) != 0
            let row = Int.random(in: state.heights.indices, using: &rng)
            let top = state.viewport.offset + state.viewport.insetTop
            let expected = ScrollAnchor.row(row, distance: state.tops[row] - top)
            let actual = ScrollAnchor.resolve(
                .row(row), heights: state.rowHeights, viewport: state.viewport, followsTail: followsTail)
            if let failure = anchorMismatch(actual, expected, tolerance: state.tolerance) {
                return XCTFail("A2 seed \(seed), \(state), row \(row), followsTail \(followsTail): \(failure)")
            }
            if followsTail, state.viewport.offset >= state.maxOffset - 1 { atTailFollowing += 1 }
        }
        XCTAssertGreaterThan(atTailFollowing, 1000, "A2 must be checked where A1 would pick the tail")
    }

    func testA3_scrollOffset() throws {
        for index in 0..<10_000 {
            let seed = 0xA300_0000 &+ UInt64(index)
            var rng = SeededGenerator(seed: seed)
            let state = AnchorState.random(&rng, elastic: true)
            let followsTail = Bool.random(using: &rng)
            let actual = ScrollAnchor.resolve(
                .scrollOffset, heights: state.rowHeights, viewport: state.viewport, followsTail: followsTail)
            if let failure = anchorMismatch(actual, .offset(state.viewport.offset), tolerance: 0) {
                return XCTFail("A3 seed \(seed), \(state), followsTail \(followsTail): \(failure)")
            }
        }
    }

    func testA4_renumbering() throws {
        var carried = 0
        var carriedMoved = 0
        var planned = 0
        for index in 0..<10_000 {
            let seed = 0xA400_0000 &+ UInt64(index)
            var rng = SeededGenerator(seed: seed)
            let state = AnchorState.random(&rng, elastic: false, minimumCount: 1)
            var batch = AnchorBatch(oldCount: state.heights.count)
            for _ in 0..<Int.random(in: 1...4, using: &rng) { batch.applyRandomEdit(&rng, big: false) }
            if let failure = batch.replayFailure { return XCTFail("A4 seed \(seed): \(failure)") }
            let newIndexes = batch.newIndexes

            // Tail and offset anchors have no row to carry; a row anchor follows its row.
            let anchor: ScrollAnchor
            switch Int.random(in: 0..<6, using: &rng) {
            case 0: anchor = .tail
            case 1: anchor = .offset(state.randomOffset(&rng, elastic: true))
            case 2:
                let row = Int.random(in: state.heights.indices, using: &rng)
                anchor = .row(row, distance: quarters(-16_000...16_000, &rng))
            default:
                anchor = state.resolve(.row(Int.random(in: state.heights.indices, using: &rng)), followsTail: false)
            }
            let expected: ScrollAnchor
            if case .row(let row, let distance) = anchor {
                guard let newRow = newIndexes[row] else { continue }  // A5's case
                expected = .row(newRow, distance: distance)
                carried += 1
                if batch.slots[newRow].moved { carriedMoved += 1 }
            } else {
                expected = anchor
            }
            let actual = anchor.mapped(through: batch.map, oldHeights: state.rowHeights, oldViewport: state.viewport)
            if let failure = anchorMismatch(actual, expected, tolerance: state.tolerance) {
                return XCTFail("A4 seed \(seed), \(state), \(anchor) through \(batch.edits): \(failure)")
            }

            // The same through a commit: `.row(r)` for a surviving r restores r
            // at its pre-batch distance.
            guard case .row(let oldRow, let distance) = anchor, case .row(let newRow, _) = expected,
                anchor == state.resolve(.row(oldRow), followsTail: false)
            else { continue }
            let newHeights = batch.newHeights(from: state.heights, &rng)
            let input = state.commitInput(
                batch: batch, newHeights: newHeights, anchoring: .row(oldRow), followsTail: Bool.random(using: &rng),
                animates: Bool.random(using: &rng))
            let newState = AnchorState(heights: newHeights, spacing: state.spacing, viewport: state.viewport)
            let target = newState.tops[newRow] - state.viewport.insetTop - distance
            guard target >= newState.minOffset, target <= newState.maxOffset else { continue }  // A7's case
            let plan = CommitPlanner.plan(input)
            let tolerance = max(state.tolerance, newState.tolerance)
            if let failure = anchorMismatch(plan.anchor, .row(newRow, distance: distance), tolerance: tolerance) {
                return XCTFail("A4 seed \(seed), \(state), .row(\(oldRow)) through \(batch.edits): plan.\(failure)")
            }
            if abs(plan.offset - target) > tolerance {
                return XCTFail(
                    "A4 seed \(seed), \(state), .row(\(oldRow)) through \(batch.edits): offset \(plan.offset), expected \(target)"
                )
            }
            planned += 1
        }
        XCTAssertGreaterThan(carried, 3000)
        XCTAssertGreaterThan(carriedMoved, 300, "A4 must carry anchors through moves")
        XCTAssertGreaterThan(planned, 1000)
    }

    func testA5_aRemovedAnchorRow() throws {
        var passedAfter = 0
        var allMoved = 0
        var replaced = 0
        var emptied = 0
        var passedBefore = 0
        for index in 0..<10_000 {
            let seed = 0xA500_0000 &+ UInt64(index)
            var rng = SeededGenerator(seed: seed)
            let state = AnchorState.random(&rng, elastic: false, minimumCount: 1)
            let followsTail = Bool.random(using: &rng)
            var anchoring = Anchoring.row(Int.random(in: state.heights.indices, using: &rng))
            if Bool.random(using: &rng), case .row = state.resolve(.automatic, followsTail: followsTail) {
                anchoring = .automatic
            }
            let anchor = state.resolve(anchoring, followsTail: followsTail)
            guard case .row(let anchorRow, _) = anchor else { return XCTFail("A5 seed \(seed): generator") }

            // Random edits, then the anchor row's removal, then maybe more.
            var batch = AnchorBatch(oldCount: state.heights.count)
            for _ in 0..<Int.random(in: 0...3, using: &rng) { batch.applyRandomEdit(&rng, big: false) }
            switch Int.random(in: 0..<8, using: &rng) {
            case 0:
                batch.apply(.remove(IndexSet(integersIn: 0..<batch.slots.count), randomTransition(&rng)))
            case 1 where batch.slots.count > 1:
                // Rows remain, but every one of them was moved.
                let count = batch.slots.count
                for _ in 0..<Int.random(in: 1...3, using: &rng) {
                    batch.apply(
                        .move(from: Int.random(in: 0..<count, using: &rng), to: Int.random(in: 0..<count, using: &rng)))
                }
                let removed = IndexSet(
                    batch.slots.indices.filter { !batch.slots[$0].moved || batch.slots[$0].old == anchorRow })
                batch.apply(.remove(removed, randomTransition(&rng)))
            default:
                guard let current = batch.slots.firstIndex(where: { $0.old == anchorRow }) else { break }
                var rows = IndexSet(integer: current)
                if Bool.random(using: &rng) {
                    rows.formUnion(randomIndexes(min(4, batch.slots.count), below: batch.slots.count, &rng))
                }
                batch.apply(.remove(rows, randomTransition(&rng)))
            }
            for _ in 0..<Int.random(in: 0...2, using: &rng) { batch.applyRandomEdit(&rng, big: false) }
            if let failure = batch.replayFailure { return XCTFail("A5 seed \(seed): \(failure)") }

            let carried = referenceCarry(anchor, batch: batch, state: state)
            let newHeights = batch.newHeights(from: state.heights, &rng)
            let newState = AnchorState(heights: newHeights, spacing: state.spacing, viewport: state.viewport)
            let tolerance = max(state.tolerance, newState.tolerance)
            func context() -> String { "A5 seed \(seed), \(state), \(anchor) through \(batch.edits)" }
            let actual = anchor.mapped(through: batch.map, oldHeights: state.rowHeights, oldViewport: state.viewport)
            let target: CGFloat
            switch carried {
            case .offset(let offset):
                // No surviving row remains: the offset, then A7.
                if let failure = anchorMismatch(actual, .offset(offset), tolerance: tolerance) {
                    return XCTFail("\(context()): no surviving row remains: \(failure)")
                }
                if batch.slots.isEmpty {
                    emptied += 1
                } else if batch.slots.contains(where: { $0.old != nil }) {
                    allMoved += 1
                } else {
                    replaced += 1
                }
                target = offset
            case .row(let newRow, let distance):
                let expected = ScrollAnchor.row(newRow, distance: distance)
                if let failure = anchorMismatch(actual, expected, tolerance: tolerance) {
                    return XCTFail("\(context()): \(failure)")
                }
                let successor = batch.slots[newRow].old!
                if successor > anchorRow { passedAfter += 1 } else { passedBefore += 1 }
                target = newState.tops[newRow] - state.viewport.insetTop - distance
            case .tail:
                return XCTFail("\(context()): reference")
            }

            // The same through a commit.
            let input = state.commitInput(
                batch: batch, newHeights: newHeights, anchoring: anchoring, followsTail: followsTail,
                animates: Bool.random(using: &rng))
            let plan = CommitPlanner.plan(input)
            let expectedOffset = newState.clamp(target)
            if abs(plan.offset - expectedOffset) > tolerance {
                return XCTFail("\(context()): plan offset \(plan.offset), expected \(expectedOffset)")
            }
        }
        XCTAssertGreaterThan(passedAfter, 3000)
        XCTAssertGreaterThan(passedBefore, 300)
        XCTAssertGreaterThan(allMoved, 300, "every remaining row moved")
        XCTAssertGreaterThan(replaced, 300, "every old row removed, rows inserted")
        XCTAssertGreaterThan(emptied, 300, "the list emptied")
    }

    func testA6_restoringEachKindOfAnchor() throws {
        var planned = 0
        for index in 0..<10_000 {
            let seed = 0xA600_0000 &+ UInt64(index)
            var rng = SeededGenerator(seed: seed)

            // Directly: a new geometry and viewport, and an anchor whose restored
            // offset lies in the new scroll range, so nothing clamps.
            let new = AnchorState.random(&rng, elastic: false)
            let target = new.randomOffset(&rng, elastic: false)
            let anchor: ScrollAnchor
            let expected: CGFloat
            switch Int.random(in: 0..<3, using: &rng) {
            case 0:
                anchor = .tail
                expected = new.maxOffset
            case 1 where !new.heights.isEmpty:
                let row = Int.random(in: new.heights.indices, using: &rng)
                anchor = .row(row, distance: new.tops[row] - new.viewport.insetTop - target)
                expected = target
            default:
                anchor = .offset(target)
                expected = target
            }
            let actual = anchor.restoredOffset(heights: new.rowHeights, viewport: new.viewport)
            if abs(actual - expected) > new.tolerance {
                return XCTFail("A6 seed \(seed), \(new), \(anchor): restored \(actual), expected \(expected)")
            }

            // Through a commit, whenever the restored offset needs no clamp.
            let state = AnchorState.random(&rng, elastic: false)
            var batch = AnchorBatch(oldCount: state.heights.count)
            for _ in 0..<Int.random(in: 0...4, using: &rng) { batch.applyRandomEdit(&rng, big: false) }
            if let failure = batch.replayFailure { return XCTFail("A6 seed \(seed): \(failure)") }
            let anchoring = state.randomAnchoring(&rng)
            let followsTail = Bool.random(using: &rng)
            let newHeights = batch.newHeights(from: state.heights, &rng)
            let newState = AnchorState(heights: newHeights, spacing: state.spacing, viewport: state.viewport)
            let unclamped = referenceTarget(
                state.resolve(anchoring, followsTail: followsTail), batch: batch, state: state, new: newState)
            guard unclamped >= newState.minOffset, unclamped <= newState.maxOffset else { continue }
            let input = state.commitInput(
                batch: batch, newHeights: newHeights, anchoring: anchoring, followsTail: followsTail,
                animates: Bool.random(using: &rng))
            let plan = CommitPlanner.plan(input)
            if abs(plan.offset - unclamped) > max(state.tolerance, newState.tolerance) {
                return XCTFail(
                    "A6 seed \(seed), \(state), \(anchoring) through \(batch.edits): offset \(plan.offset), expected \(unclamped)"
                )
            }
            planned += 1
        }
        XCTAssertGreaterThan(planned, 5000)
    }

    func testA7_clampingIsTheOnlyException() throws {
        var clampedDirectly = 0
        var clampedPlans = 0
        for index in 0..<10_000 {
            let seed = 0xA700_0000 &+ UInt64(index)
            var rng = SeededGenerator(seed: seed)

            // Directly: anchors that ask for an offset outside the new range, or inside it.
            let new = AnchorState.random(&rng, elastic: false)
            let target: CGFloat
            switch Int.random(in: 0..<5, using: &rng) {
            case 0, 1: target = new.minOffset - quarters(1...16_000, &rng)
            case 2, 3: target = new.maxOffset + quarters(1...16_000, &rng)
            default: target = new.randomOffset(&rng, elastic: false)
            }
            let anchor: ScrollAnchor
            if !new.heights.isEmpty, Bool.random(using: &rng) {
                let row = Int.random(in: new.heights.indices, using: &rng)
                anchor = .row(row, distance: new.tops[row] - new.viewport.insetTop - target)
            } else {
                anchor = .offset(target)
            }
            let expected = new.clamp(target)
            let actual = anchor.restoredOffset(heights: new.rowHeights, viewport: new.viewport)
            if abs(actual - expected) > new.tolerance {
                return XCTFail("A7 seed \(seed), \(new), \(anchor): restored \(actual), expected \(expected)")
            }
            if expected != target { clampedDirectly += 1 }

            // Through a commit: big removals and `.scrollOffset` push the restored
            // offset out of range.
            let state = AnchorState.random(&rng, elastic: false)
            var batch = AnchorBatch(oldCount: state.heights.count)
            let big = Bool.random(using: &rng)
            for _ in 0..<Int.random(in: 1...4, using: &rng) { batch.applyRandomEdit(&rng, big: big) }
            if let failure = batch.replayFailure { return XCTFail("A7 seed \(seed): \(failure)") }
            let anchoring = state.randomAnchoring(&rng)
            let followsTail = Bool.random(using: &rng)
            let newHeights = batch.newHeights(from: state.heights, &rng)
            let newState = AnchorState(heights: newHeights, spacing: state.spacing, viewport: state.viewport)
            let unclamped = referenceTarget(
                state.resolve(anchoring, followsTail: followsTail), batch: batch, state: state, new: newState)
            let input = state.commitInput(
                batch: batch, newHeights: newHeights, anchoring: anchoring, followsTail: followsTail,
                animates: Bool.random(using: &rng))
            let plan = CommitPlanner.plan(input)
            let clamped = newState.clamp(unclamped)
            if abs(plan.offset - clamped) > max(state.tolerance, newState.tolerance) {
                return XCTFail(
                    "A7 seed \(seed), \(state), \(anchoring) through \(batch.edits): offset \(plan.offset), expected \(clamped) (unclamped \(unclamped))"
                )
            }
            if clamped != unclamped { clampedPlans += 1 }
        }
        XCTAssertGreaterThan(clampedDirectly, 3000)
        XCTAssertGreaterThan(clampedPlans, 1000)
    }

    func testW2_theAnchorComesFirst() throws {
        var rescaledPlans = 0
        var tailPlans = 0
        for index in 0..<10_000 {
            let seed = 0x5720_0000 &+ UInt64(index)
            var rng = SeededGenerator(seed: seed)

            // Directly: d' = d · h' / h; other anchors are unchanged.
            let old = randomHeight(&rng)
            let new = randomHeight(&rng)
            let distance = quarters(-16_000...16_000, &rng)
            let row = Int.random(in: 0..<100, using: &rng)
            let offset = quarters(-16_000...16_000, &rng)
            let tolerance = 1e-6 * max(1, abs(distance) * max(1, new / old))
            let cases: [(ScrollAnchor, ScrollAnchor)] = [
                (.row(row, distance: distance), .row(row, distance: distance * new / old)),
                (.tail, .tail), (.offset(offset), .offset(offset)),
            ]
            for (anchor, expected) in cases {
                let actual = anchor.rescaled(fromHeight: old, toHeight: new)
                if let failure = anchorMismatch(actual, expected, tolerance: tolerance) {
                    return XCTFail("W2 seed \(seed), \(anchor) from \(old) to \(new): \(failure)")
                }
            }

            // Through a width change: the identity map, every row possibly
            // re-measured, `.automatic` anchoring, no animation (M1).
            let state = AnchorState.random(&rng, elastic: false)
            let newHeights = state.heights.map { Int.random(in: 0..<10, using: &rng) < 3 ? $0 : randomHeight(&rng) }
            let newState = AnchorState(heights: newHeights, spacing: state.spacing, viewport: state.viewport)
            let followsTail = Bool.random(using: &rng)
            let anchor = state.resolve(.automatic, followsTail: followsTail)
            let expected: ScrollAnchor
            let unclamped: CGFloat
            switch anchor {
            case .tail:
                expected = .tail
                unclamped = newState.maxOffset
                tailPlans += 1
            case .offset(let offset):
                expected = .offset(offset)
                unclamped = offset
            case .row(let row, let distance):
                let rescaled = distance * newHeights[row] / state.heights[row]
                expected = .row(row, distance: rescaled)
                unclamped = newState.tops[row] - state.viewport.insetTop - rescaled
                rescaledPlans += 1
            }
            let input = CommitInput(
                oldHeights: state.rowHeights, newHeights: newState.rowHeights,
                map: RowIndexMap(oldCount: state.heights.count), oldViewport: state.viewport,
                newViewport: state.viewport, anchoring: .automatic, followsTail: followsTail, rescalesAnchor: true,
                mountedRows: state.preparedRows, animates: false)
            let plan = CommitPlanner.plan(input)
            let planTolerance = max(state.tolerance, newState.tolerance)
            func context() -> String {
                "W2 seed \(seed), \(state), followsTail \(followsTail), heights \(state.heights) → \(newHeights)"
            }
            let clamped = newState.clamp(unclamped)
            if abs(plan.offset - clamped) > planTolerance {
                return XCTFail("\(context()): offset \(plan.offset), expected \(clamped) (unclamped \(unclamped))")
            }
            if clamped == unclamped, let failure = anchorMismatch(plan.anchor, expected, tolerance: planTolerance) {
                return XCTFail("\(context()): plan.\(failure)")
            }
        }
        XCTAssertGreaterThan(rescaledPlans, 5000)
        XCTAssertGreaterThan(tailPlans, 500)
    }
}

// MARK: - The reference

/// A value in quarter points. Sums of these are exact in any order, so the
/// reference and the code under test agree bit for bit on every comparison,
/// and a probe on a boundary means what it says.
private func quarters(_ range: ClosedRange<Int>, _ rng: inout SeededGenerator) -> CGFloat {
    CGFloat(Int.random(in: range, using: &rng)) / 4
}

/// 1–300 pt, and one in ten 300–3000 pt.
private func randomHeight(_ rng: inout SeededGenerator) -> CGFloat {
    Int.random(in: 0..<10, using: &rng) == 0 ? quarters(1200...12_000, &rng) : quarters(4...1200, &rng)
}

private func randomTransition(_ rng: inout SeededGenerator) -> RowTransition {
    let transitions: [RowTransition] = [
        [], .effectFade, .effectGap, .slideUp, .slideDown, [.effectFade, .slideLeft], .slideRight,
    ]
    return transitions.randomElement(using: &rng)!
}

/// `count` distinct indexes below `bound`: a run half the time, scattered otherwise.
private func randomIndexes(_ count: Int, below bound: Int, _ rng: inout SeededGenerator) -> IndexSet {
    if Bool.random(using: &rng) {
        let start = Int.random(in: 0...(bound - count), using: &rng)
        return IndexSet(integersIn: start..<(start + count))
    }
    var indexes = IndexSet()
    while indexes.count < count { indexes.insert(Int.random(in: 0..<bound, using: &rng)) }
    return indexes
}

private func kindName(_ anchor: ScrollAnchor) -> String {
    switch anchor {
    case .tail: return "tail"
    case .row: return "row"
    case .offset: return "offset"
    }
}

private func anchorMismatch(_ actual: ScrollAnchor, _ expected: ScrollAnchor, tolerance: CGFloat) -> String? {
    switch (actual, expected) {
    case (.tail, .tail):
        return nil
    case (.row(let row, let distance), .row(let expectedRow, let expectedDistance))
    where row == expectedRow && abs(distance - expectedDistance) <= tolerance:
        return nil
    case (.offset(let offset), .offset(let expectedOffset)) where abs(offset - expectedOffset) <= tolerance:
        return nil
    default:
        return "anchor \(actual), expected \(expected)"
    }
}

/// A list and its viewport, with G1–G3 worked out the naive way.
private struct AnchorState: CustomStringConvertible {

    var heights: [CGFloat]
    var spacing: CGFloat
    var viewport: Viewport

    var tops: [CGFloat] { ReferenceGeometry.tops(heights: heights, spacing: spacing) }
    var contentHeight: CGFloat { ReferenceGeometry.contentHeight(heights: heights, spacing: spacing) }
    var minOffset: CGFloat { -viewport.insetTop }
    var maxOffset: CGFloat { max(minOffset, contentHeight - viewport.height + viewport.insetBottom) }
    var rowHeights: RowHeights { RowHeights(heights, spacing: spacing) }
    var tolerance: CGFloat { 1e-6 * max(1, contentHeight) }

    func clamp(_ offset: CGFloat) -> CGFloat { min(max(offset, minOffset), maxOffset) }

    /// The rows whose frames meet the prepared area, which P1 keeps mounted.
    var preparedRows: IndexSet {
        let overscan = (viewport.height - viewport.insetTop - viewport.insetBottom) / 2
        let lower = viewport.offset + viewport.insetTop - overscan
        let upper = viewport.offset + viewport.height - viewport.insetBottom + overscan
        let tops = self.tops
        return IndexSet(heights.indices.filter { tops[$0] < upper && tops[$0] + heights[$0] > lower })
    }

    var description: String {
        "n \(heights.count), s \(spacing), o \(viewport.offset), V \(viewport.height), "
            + "t \(viewport.insetTop), b \(viewport.insetBottom), heights \(heights)"
    }

    static func random(_ rng: inout SeededGenerator, elastic: Bool, minimumCount: Int = 0) -> AnchorState {
        let count: Int
        switch Int.random(in: 0..<20, using: &rng) {
        case 0: count = 0
        case 1: count = 1
        case 2..<8: count = Int.random(in: 2...8, using: &rng)
        default: count = Int.random(in: 9...40, using: &rng)
        }
        let heights = (0..<max(count, minimumCount)).map { _ in randomHeight(&rng) }
        let spacing = Bool.random(using: &rng) ? 0 : quarters(1...64, &rng)
        let insetTop = Bool.random(using: &rng) ? 0 : quarters(1...320, &rng)
        let insetBottom = Bool.random(using: &rng) ? 0 : quarters(1...320, &rng)
        let height = max(quarters(160...3200, &rng), insetTop + insetBottom + 20)
        var state = AnchorState(
            heights: heights, spacing: spacing,
            viewport: Viewport(offset: 0, height: height, insetTop: insetTop, insetBottom: insetBottom))
        state.viewport.offset = state.randomOffset(&rng, elastic: elastic)
        return state
    }

    /// The top, the tail, either side of the tail tolerance, anywhere, a row
    /// edge exactly at the top of U, or (when `elastic`) past either end.
    func randomOffset(_ rng: inout SeededGenerator, elastic: Bool) -> CGFloat {
        let low = minOffset
        let high = maxOffset
        let anywhere = low + quarters(0...Int((high - low) * 4), &rng)
        switch Int.random(in: 0..<20, using: &rng) {
        case 0..<4:
            return low
        case 4..<8:
            return high
        case 8, 9:
            return max(low, high - 1)
        case 10:
            return max(low, high - 1.25)
        case 11..<15:
            return anywhere
        case 15..<18:
            guard !heights.isEmpty else { return low }
            let tops = self.tops
            let row = Int.random(in: heights.indices, using: &rng)
            let bottom = tops[row] + heights[row]
            let edges = [tops[row], bottom, bottom + spacing / 2, bottom + spacing]
            return clamp(edges.randomElement(using: &rng)! - viewport.insetTop)
        default:
            guard elastic else { return anywhere }
            return Bool.random(using: &rng) ? high + quarters(1...800, &rng) : low - quarters(1...800, &rng)
        }
    }

    func randomAnchoring(_ rng: inout SeededGenerator) -> Anchoring {
        switch Int.random(in: 0..<10, using: &rng) {
        case 0..<6: return .automatic
        case 6...7 where !heights.isEmpty: return .row(Int.random(in: heights.indices, using: &rng))
        default: return .scrollOffset
        }
    }

    /// A1–A3, written from the spec: a linear scan for the first visible row.
    func resolve(_ anchoring: Anchoring, followsTail: Bool) -> ScrollAnchor {
        let top = viewport.offset + viewport.insetTop
        let tops = self.tops
        switch anchoring {
        case .automatic:
            if followsTail, viewport.offset >= maxOffset - 1 { return .tail }
            for row in heights.indices where tops[row] + heights[row] > top {
                return .row(row, distance: tops[row] - top)
            }
            return .offset(viewport.offset)
        case .row(let row):
            return .row(row, distance: tops[row] - top)
        case .scrollOffset:
            return .offset(viewport.offset)
        }
    }

    /// A batch's input with this state before it and the same viewport after.
    func commitInput(
        batch: AnchorBatch, newHeights: [CGFloat], anchoring: Anchoring, followsTail: Bool, animates: Bool
    ) -> CommitInput {
        CommitInput(
            oldHeights: rowHeights, newHeights: RowHeights(newHeights, spacing: spacing), map: batch.map,
            oldViewport: viewport, newViewport: viewport, anchoring: anchoring, followsTail: followsTail,
            rescalesAnchor: false, mountedRows: preparedRows, animates: animates)
    }
}

/// A batch replayed on plain arrays, one edit at a time (U2), tracking which
/// rows were moved.
private struct AnchorBatch {

    struct Slot {
        var old: Int?
        var moved = false
        var noted = false
    }

    let oldCount: Int
    private(set) var edits: [RowEdit] = []
    private(set) var slots: [Slot]

    init(oldCount: Int) {
        self.oldCount = oldCount
        slots = (0..<oldCount).map { Slot(old: $0) }
    }

    mutating func apply(_ edit: RowEdit) {
        edits.append(edit)
        switch edit {
        case .insert(let indexes, _):
            for index in indexes { slots.insert(Slot(old: nil), at: index) }
        case .remove(let indexes, _):
            for index in indexes.reversed() { slots.remove(at: index) }
        case .move(let from, let to):
            var slot = slots.remove(at: from)
            slot.moved = slot.old != nil
            slots.insert(slot, at: to)
        case .noteHeight(let indexes):
            for index in indexes where slots[index].old != nil { slots[index].noted = true }
        case .reload:
            break
        }
    }

    mutating func applyRandomEdit(_ rng: inout SeededGenerator, big: Bool) {
        let count = slots.count
        let most = big ? 12 : 3
        switch Int.random(in: 0..<10, using: &rng) {
        case 0..<3:
            let inserted = Int.random(in: 1...most, using: &rng)
            apply(.insert(randomIndexes(inserted, below: count + inserted, &rng), randomTransition(&rng)))
        case 3..<6 where count > 0:
            let removed = Int.random(in: 1...min(most, count), using: &rng)
            apply(.remove(randomIndexes(removed, below: count, &rng), randomTransition(&rng)))
        case 6...7 where count > 0:
            apply(.move(from: Int.random(in: 0..<count, using: &rng), to: Int.random(in: 0..<count, using: &rng)))
        case 8 where count > 0:
            apply(.noteHeight(randomIndexes(Int.random(in: 1...min(3, count), using: &rng), below: count, &rng)))
        case 9 where count > 0:
            apply(.reload(randomIndexes(Int.random(in: 1...min(3, count), using: &rng), below: count, &rng)))
        default:
            break
        }
    }

    /// The map under test, built from the same edits.
    var map: RowIndexMap {
        var map = RowIndexMap(oldCount: oldCount)
        for edit in edits { map.apply(edit) }
        return map
    }

    /// Each old row's new index, or `nil` once removed.
    var newIndexes: [Int?] {
        var indexes = [Int?](repeating: nil, count: oldCount)
        for (row, slot) in slots.enumerated() {
            if let old = slot.old { indexes[old] = row }
        }
        return indexes
    }

    /// A test bug guard: this replay and `ReferenceGeometry.replay` must agree.
    var replayFailure: String? {
        slots.map(\.old) == ReferenceGeometry.replay(oldCount: oldCount, edits: edits)
            ? nil : "the two references disagree on \(edits)"
    }

    /// Survivors keep their height unless noted; inserted and noted rows are
    /// measured afresh.
    func newHeights(from old: [CGFloat], _ rng: inout SeededGenerator) -> [CGFloat] {
        slots.map { slot in
            guard let row = slot.old else { return randomHeight(&rng) }
            return slot.noted && Bool.random(using: &rng) ? randomHeight(&rng) : old[row]
        }
    }
}

/// A4 and A5, written from the spec. "Surviving" is neither removed nor
/// moved; when no surviving row remains, the anchor becomes the offset.
private func referenceCarry(_ anchor: ScrollAnchor, batch: AnchorBatch, state: AnchorState) -> ScrollAnchor {
    guard case .row(let row, let distance) = anchor else { return anchor }
    let newIndexes = batch.newIndexes
    if let newRow = newIndexes[row] { return .row(newRow, distance: distance) }
    let survives = { (old: Int) -> Bool in
        guard let new = newIndexes[old] else { return false }
        return !batch.slots[new].moved
    }
    guard let successor = (row + 1..<batch.oldCount).first(where: survives) ?? (0..<row).last(where: survives)
    else { return .offset(state.viewport.offset) }
    let top = state.viewport.offset + state.viewport.insetTop
    return .row(newIndexes[successor]!, distance: state.tops[successor] - top)
}

/// A6 before A7's clamp, for an anchor resolved against `state` and carried
/// through `batch`.
private func referenceTarget(
    _ anchor: ScrollAnchor, batch: AnchorBatch, state: AnchorState, new: AnchorState
) -> CGFloat {
    switch referenceCarry(anchor, batch: batch, state: state) {
    case .tail:
        return new.maxOffset
    case .offset(let offset):
        return offset
    case .row(let row, let distance):
        return new.tops[row] - new.viewport.insetTop - distance
    }
}
