import XCTest

@testable import ExactListCore

/// Planned motion against M2's formulas, evaluated from the test's own heights: §8.2.
///
/// Each method proves the requirement in its name. `SpecCoverageTests` checks
/// that every ID in `SPEC.md` has one.
final class CommitPlannerTests: XCTestCase {

    func testM2_linearInterpolation() throws {
        var tally = Tally()
        for index in 0..<10_000 {
            let seed = 0x4D20_0000 &+ UInt64(index)
            var rng = SeededGenerator(seed: seed)
            let commit = Commit.random(&rng, bigJumps: Int.random(in: 0..<4, using: &rng) == 0)
            if let failure = commit.replayFailure { return XCTFail("M2 seed \(seed): \(failure)") }
            let reference = Reference(commit)
            if let reason = reference.ambiguity {
                tally.skip(reason)
                continue
            }
            let plan = CommitPlanner.plan(commit.input)
            if let failure = reference.mismatch(plan, commit) {
                return XCTFail("M2 seed \(seed), \(commit): \(failure)")
            }
            tally.record(commit, reference, plan)
        }
        // Every fallback of M2's two rules, gaps holding both kinds of row, and
        // batches where every remaining row was moved.
        tally.assertCoverage(
            checked: 9000,
            motions: [
                "inserted": 3000, "removed": 3000, "moved": 1000, "gap with removed and inserted rows": 1000,
                "every remaining row moved": 500, "inserted rule 1": 1000, "inserted rule 2": 1000,
                "inserted rule 3": 300, "inserted rule 4": 100, "removed rule 1": 500, "removed rule 2": 500,
                "removed rule 3": 100, "removed rule 4": 500, "every old row removed, rows inserted": 200,
                "A5 anchor with no survivor": 300,
            ])
    }

    func testM4_theAnchorIsStill() throws {
        var tally = Tally()
        var unclamped = 0
        var clamped = 0
        for index in 0..<10_000 {
            let seed = 0x4D40_0000 &+ UInt64(index)
            var rng = SeededGenerator(seed: seed)
            let commit = Commit.random(
                &rng, bigJumps: Int.random(in: 0..<4, using: &rng) == 0, batchesOnly: true, animates: true)
            if let failure = commit.replayFailure { return XCTFail("M4 seed \(seed): \(failure)") }
            let reference = Reference(commit)
            if let reason = reference.ambiguity {
                tally.skip(reason)
                continue
            }
            let plan = CommitPlanner.plan(commit.input)
            tally.record(commit, reference, plan)
            guard let row = reference.anchorRow else { continue }  // tail, offset, or nothing survived
            guard let motion = plan.motions.first(where: { $0.kind != .removed && $0.row == row }) else {
                if reference.motions.contains(where: {
                    $0.kind != .removed && $0.row == row && $0.presence == .required
                }) {
                    return XCTFail("M4 seed \(seed), \(commit): the anchor row \(row) has no motion")
                }
                continue
            }
            let tolerance = reference.tolerance
            func context() -> String { "M4 seed \(seed), \(commit): anchor row \(row), \(motion)" }
            // The anchor row ends where the restored offset puts it, which is
            // where it was unless A7 clamped: o* − o' away.
            let shift = reference.unclampedOffset - reference.offset
            if abs(motion.endTop - (reference.anchorStartTop + shift)) > tolerance {
                return XCTFail("\(context()): ends at \(motion.endTop), expected \(reference.anchorStartTop + shift)")
            }
            if reference.offset == reference.unclampedOffset {
                for p: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
                    let top = ReferenceGeometry.presented(start: motion.startTop, end: motion.endTop, progress: p)
                    if abs(top - reference.anchorStartTop) > tolerance {
                        return XCTFail("\(context()): at p = \(p) it is at \(top), not \(reference.anchorStartTop)")
                    }
                }
                unclamped += 1
            } else {
                // Clamped: it moves along the interpolation, by the clamp, scaled by M7.
                let expected = -reference.amplitude * shift
                if abs((motion.startTop - motion.endTop) - expected) > tolerance {
                    return XCTFail(
                        "\(context()): moves by \(motion.startTop - motion.endTop), expected \(expected) (k \(reference.amplitude))"
                    )
                }
                clamped += 1
            }
        }
        XCTAssertGreaterThan(unclamped, 2500)
        XCTAssertGreaterThan(clamped, 300)
        tally.assertFewSkips()
    }

    func testM5_rowsStayContiguous() throws {
        var tally = Tally()
        var pairs = 0
        var exactPairs = 0
        for index in 0..<10_000 {
            let seed = 0x4D50_0000 &+ UInt64(index)
            var rng = SeededGenerator(seed: seed)
            let commit = Commit.random(
                &rng, bigJumps: Int.random(in: 0..<4, using: &rng) == 0,
                animates: Int.random(in: 0..<8, using: &rng) == 0 ? nil : true)
            if let failure = commit.replayFailure { return XCTFail("M5 seed \(seed): \(failure)") }
            let reference = Reference(commit)
            if let reason = reference.ambiguity {
                tally.skip(reason)
                continue
            }
            let plan = CommitPlanner.plan(commit.input)
            tally.record(commit, reference, plan)
            var planned: [Key: RowMotion] = [:]
            for motion in plan.motions where motion.kind != .moved {
                // A removed row in a commit that doesn't animate has no defined motion.
                if motion.kind == .removed, !commit.animates { continue }
                planned[Key(motion)] = motion
            }
            let order = PresentedOrder(commit, planned: Set(planned.keys))
            for (upper, lower) in zip(order.items, order.items.dropFirst()) {
                let a = planned[upper.key]!
                let b = planned[lower.key]!
                let adjacent =
                    upper.survivor != nil && lower.survivor != nil && lower.survivor!.old == upper.survivor!.old + 1
                    && lower.survivor!.new == upper.survivor!.new + 1
                for p: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
                    let top = ReferenceGeometry.presented(start: a.startTop, end: a.endTop, progress: p)
                    let height = ReferenceGeometry.presented(start: a.startHeight, end: a.endHeight, progress: p)
                    let next = ReferenceGeometry.presented(start: b.startTop, end: b.endTop, progress: p)
                    let gap = next - (top + height)
                    func context() -> String { "M5 seed \(seed), \(commit): at p = \(p), \(a) then \(b)" }
                    if gap < -reference.tolerance {
                        return XCTFail("\(context()): they overlap by \(-gap)")
                    }
                    if adjacent, abs(gap - commit.newSpacing) > reference.tolerance {
                        return XCTFail(
                            "\(context()): adjacent survivors are \(gap) apart, not s = \(commit.newSpacing)")
                    }
                }
                pairs += 1
                if adjacent { exactPairs += 1 }
            }
        }
        XCTAssertGreaterThan(pairs, 15_000)
        XCTAssertGreaterThan(exactPairs, 10_000)
        tally.assertFewSkips()
    }

    func testM7_theAmplitudeCap() throws {
        var tally = Tally()
        var capped = 0
        for index in 0..<10_000 {
            let seed = 0x4D70_0000 &+ UInt64(index)
            var rng = SeededGenerator(seed: seed)
            let commit = Commit.random(
                &rng, bigJumps: Int.random(in: 0..<4, using: &rng) != 0, batchesOnly: true,
                animates: Int.random(in: 0..<10, using: &rng) == 0 ? nil : true)
            if let failure = commit.replayFailure { return XCTFail("M7 seed \(seed): \(failure)") }
            let reference = Reference(commit)
            if let reason = reference.ambiguity {
                tally.skip(reason)
                continue
            }
            let plan = CommitPlanner.plan(commit.input)
            tally.record(commit, reference, plan)
            let k = reference.amplitude
            func context() -> String { "M7 seed \(seed), \(commit)" }
            if abs(plan.amplitude - k) > 1e-9 {
                return XCTFail("\(context()): amplitude \(plan.amplitude), expected \(k)")
            }
            let expected = Dictionary(uniqueKeysWithValues: reference.motions.map { (Key($0.kind, $0.row), $0) })
            for motion in plan.motions {
                guard let row = expected[Key(motion)], row.valuesDefined else { continue }  // M2 judges these
                if k < 1, abs(motion.startTop - motion.endTop) > reference.unobscuredHeight + reference.tolerance {
                    return XCTFail("\(context()): \(motion) moves more than C = \(reference.unobscuredHeight)")
                }
                // start = end + k·(naive start − end), for tops and heights alike.
                let top = row.endTop + k * (row.naiveStartTop - row.endTop)
                let height = row.endHeight + k * (row.naiveStartHeight - row.endHeight)
                if abs(motion.startTop - top) > reference.tolerance
                    || abs(motion.startHeight - height) > reference.tolerance
                {
                    return XCTFail(
                        "\(context()): \(motion) starts at (\(motion.startTop), \(motion.startHeight)), expected (\(top), \(height)) with k \(k)"
                    )
                }
            }
            if k < 1 { capped += 1 }
        }
        XCTAssertGreaterThan(capped, 1500, "M7 generator rarely caps")
        tally.assertFewSkips()
    }
}

// MARK: - Generating commits

/// A value in quarter points. Sums of these are exact in any order, so the
/// reference and the code under test agree bit for bit on every discrete
/// decision (the first visible row, the tail, the clamp).
private func quarters(_ range: ClosedRange<Int>, _ rng: inout SeededGenerator) -> CGFloat {
    CGFloat(Int.random(in: range, using: &rng)) / 4
}

/// 1–300 pt, and one in ten 300–3000 pt; with `tall`, one in three.
private func randomHeight(_ rng: inout SeededGenerator, tall: Bool = false) -> CGFloat {
    Int.random(in: 0..<(tall ? 3 : 10), using: &rng) == 0 ? quarters(1200...12_000, &rng) : quarters(4...1200, &rng)
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

/// One row of the new numbering, replayed on a plain array.
private struct Slot {
    var old: Int?
    var moved = false
    var noted = false
    var transition: RowTransition = []
}

/// One commit's input, generated from values the test chose, with the batch
/// replayed naively beside the map under test.
private struct Commit: CustomStringConvertible {

    enum Kind: String {
        case batch, width, viewport, spacing
    }

    var kind = Kind.batch
    var oldHeights: [CGFloat]
    var oldSpacing: CGFloat
    var oldViewport: Viewport
    var newHeights: [CGFloat]
    var newSpacing: CGFloat
    var newViewport: Viewport
    var edits: [RowEdit] = []
    var slots: [Slot]
    var removals: [Int: RowTransition] = [:]
    var anchoring = Anchoring.automatic
    var followsTail = false
    var mounted = IndexSet()
    var animates = false

    var rescalesAnchor: Bool { kind == .width }

    var input: CommitInput {
        var map = RowIndexMap(oldCount: oldHeights.count)
        for edit in edits { map.apply(edit) }
        return CommitInput(
            oldHeights: RowHeights(oldHeights, spacing: oldSpacing),
            newHeights: RowHeights(newHeights, spacing: newSpacing),
            map: map, oldViewport: oldViewport, newViewport: newViewport, anchoring: anchoring,
            followsTail: followsTail, rescalesAnchor: rescalesAnchor, mountedRows: mounted, animates: animates)
    }

    /// A test bug guard: this replay and `ReferenceGeometry.replay` must agree.
    var replayFailure: String? {
        slots.map(\.old) == ReferenceGeometry.replay(oldCount: oldHeights.count, edits: edits)
            ? nil : "the two references disagree on \(edits)"
    }

    var description: String {
        let old = oldViewport
        let new = newViewport
        return "\(kind) \(anchoring) followsTail \(followsTail) animates \(animates); "
            + "old: s \(oldSpacing), o \(old.offset), V \(old.height), t \(old.insetTop), b \(old.insetBottom), "
            + "heights \(oldHeights); edits \(edits); "
            + "new: s \(newSpacing), V \(new.height), t \(new.insetTop), b \(new.insetBottom), heights \(newHeights); "
            + "mounted \(Array(mounted))"
    }

    /// `bigJumps` favours tall rows, large inserts and removals, and
    /// `.scrollOffset`, which is what makes M7 cap. `animates` forces M1's
    /// answer for batches; `nil` leaves it random.
    static func random(
        _ rng: inout SeededGenerator, bigJumps: Bool, batchesOnly: Bool = false, animates: Bool? = nil
    ) -> Commit {
        let count: Int
        switch Int.random(in: 0..<20, using: &rng) {
        case 0: count = 0
        case 1: count = 1
        case 2..<8: count = Int.random(in: 2...8, using: &rng)
        default: count = Int.random(in: 9...40, using: &rng)
        }
        let heights = (0..<count).map { _ in randomHeight(&rng, tall: bigJumps) }
        let spacing = Bool.random(using: &rng) ? 0 : quarters(1...64, &rng)
        let viewport = randomViewport(&rng)
        var commit = Commit(
            oldHeights: heights, oldSpacing: spacing, oldViewport: viewport, newHeights: heights, newSpacing: spacing,
            newViewport: viewport, slots: (0..<count).map { Slot(old: $0) })
        commit.oldViewport.offset = commit.randomOffset(&rng)
        commit.newViewport.offset = commit.oldViewport.offset
        commit.followsTail = Bool.random(using: &rng)
        if bigJumps, Int.random(in: 0..<3, using: &rng) != 0 {
            commit.followsTail = true
        }

        let roll = batchesOnly ? 0 : Int.random(in: 0..<20, using: &rng)
        switch roll {
        case 0..<16:
            // Recipes for M2's harder gaps, then random edits.
            var edits = 1...4
            switch Int.random(in: 0..<8, using: &rng) {
            case 0:
                commit.applyReplacement(&rng, big: bigJumps)
                edits = 0...2
            case 1 where count > 1:
                commit.moveEveryRemainingRow(&rng)
                edits = 0...2
            default:
                break
            }
            for _ in 0..<Int.random(in: edits, using: &rng) { commit.applyRandomEdit(&rng, big: bigJumps) }
            commit.newHeights = commit.slots.map { slot in
                guard let row = slot.old else { return randomHeight(&rng, tall: bigJumps) }
                return slot.noted && Bool.random(using: &rng) ? randomHeight(&rng, tall: bigJumps) : heights[row]
            }
            switch Int.random(in: 0..<10, using: &rng) {
            case 0..<(bigJumps ? 4 : 6): commit.anchoring = .automatic
            case 6..<8 where count > 0: commit.anchoring = .row(Int.random(in: 0..<count, using: &rng))
            default: commit.anchoring = .scrollOffset
            }
            commit.animates = animates ?? (Int.random(in: 0..<4, using: &rng) != 0)
        case 16, 17:
            // A width change (W2): identity map, some rows re-measured; never animates (M1).
            commit.kind = .width
            commit.newHeights = heights.map { Int.random(in: 0..<10, using: &rng) < 3 ? $0 : randomHeight(&rng) }
        case 18:
            // A viewport or inset change (V1, V2): never animates.
            commit.kind = .viewport
            commit.newViewport = randomViewport(&rng)
            commit.newViewport.offset = commit.oldViewport.offset
        default:
            // A spacing change (V3): never animates.
            commit.kind = .spacing
            commit.newSpacing = quarters(0...64, &rng)
        }

        commit.mounted = commit.preparedRows
        if Int.random(in: 0..<10, using: &rng) == 0, count > 0 {
            for _ in 0..<Int.random(in: 1...3, using: &rng) {
                commit.mounted.insert(Int.random(in: 0..<count, using: &rng))
            }
        }
        return commit
    }

    static func randomViewport(_ rng: inout SeededGenerator) -> Viewport {
        let insetTop = Bool.random(using: &rng) ? 0 : quarters(1...320, &rng)
        let insetBottom = Bool.random(using: &rng) ? 0 : quarters(1...320, &rng)
        let height = max(quarters(160...3200, &rng), insetTop + insetBottom + 20)
        return Viewport(offset: 0, height: height, insetTop: insetTop, insetBottom: insetBottom)
    }

    /// The top, the tail, either side of the tail tolerance, anywhere, a row
    /// edge exactly at the top of U, and rarely past either end.
    func randomOffset(_ rng: inout SeededGenerator) -> CGFloat {
        let tops = ReferenceGeometry.tops(heights: oldHeights, spacing: oldSpacing)
        let content = ReferenceGeometry.contentHeight(heights: oldHeights, spacing: oldSpacing)
        let low = -oldViewport.insetTop
        let high = max(low, content - oldViewport.height + oldViewport.insetBottom)
        let anywhere = low + quarters(0...Int((high - low) * 4), &rng)
        switch Int.random(in: 0..<40, using: &rng) {
        case 0..<8:
            return low
        case 8..<16:
            return high
        case 16..<19:
            return max(low, high - 1)
        case 19:
            return max(low, high - 1.25)
        case 20..<30:
            return anywhere
        case 30..<38:
            guard !oldHeights.isEmpty else { return low }
            let row = Int.random(in: oldHeights.indices, using: &rng)
            let bottom = tops[row] + oldHeights[row]
            let edges = [tops[row], bottom, bottom + oldSpacing / 2, bottom + oldSpacing]
            return min(max(edges.randomElement(using: &rng)! - oldViewport.insetTop, low), high)
        default:
            return Bool.random(using: &rng) ? high + quarters(1...800, &rng) : low - quarters(1...800, &rng)
        }
    }

    /// The old rows whose frames meet the old prepared area (P1).
    var preparedRows: IndexSet {
        let tops = ReferenceGeometry.tops(heights: oldHeights, spacing: oldSpacing)
        let viewport = oldViewport
        let overscan = (viewport.height - viewport.insetTop - viewport.insetBottom) / 2
        let lower = viewport.offset + viewport.insetTop - overscan
        let upper = viewport.offset + viewport.height - viewport.insetBottom + overscan
        return IndexSet(oldHeights.indices.filter { tops[$0] < upper && tops[$0] + oldHeights[$0] > lower })
    }

    mutating func apply(_ edit: RowEdit) {
        edits.append(edit)
        switch edit {
        case .insert(let indexes, let transition):
            for index in indexes { slots.insert(Slot(old: nil, transition: transition), at: index) }
        case .remove(let indexes, let transition):
            for index in indexes.reversed() {
                if let old = slots.remove(at: index).old { removals[old] = transition }
            }
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

    /// Removes a run and inserts rows at the same place, often at the top, so
    /// one gap holds both kinds of row, sometimes with no survivor before it.
    mutating func applyReplacement(_ rng: inout SeededGenerator, big: Bool) {
        let count = slots.count
        let most = big ? 12 : 3
        let at = Bool.random(using: &rng) ? 0 : Int.random(in: 0...count, using: &rng)
        if at < count {
            let removed = Int.random(in: 1...min(most, count - at), using: &rng)
            apply(.remove(IndexSet(integersIn: at..<(at + removed)), randomTransition(&rng)))
        }
        let inserted = Int.random(in: 1...most, using: &rng)
        apply(.insert(IndexSet(integersIn: at..<(at + inserted)), randomTransition(&rng)))
    }

    /// Moves a few rows, then removes every row that wasn't moved: rows
    /// remain, but none survives (A5, M2's fallbacks).
    mutating func moveEveryRemainingRow(_ rng: inout SeededGenerator) {
        let count = slots.count
        for _ in 0..<Int.random(in: 1...3, using: &rng) {
            apply(.move(from: Int.random(in: 0..<count, using: &rng), to: Int.random(in: 0..<count, using: &rng)))
        }
        let unmoved = IndexSet(slots.indices.filter { !slots[$0].moved })
        if !unmoved.isEmpty { apply(.remove(unmoved, randomTransition(&rng))) }
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
}

// MARK: - The reference

/// A motion's identity: new index, or old index for a removed row.
private struct Key: Hashable {
    var removed: Bool
    var row: Int

    init(_ kind: RowMotion.Kind, _ row: Int) {
        removed = kind == .removed
        self.row = row
    }

    init(_ motion: RowMotion) {
        self.init(motion.kind, motion.row)
    }
}

/// §6 and §8.2 worked out from the commit's own arrays: A1–A7 and W2 for the
/// offset, then M2's start and end for every candidate row, M7's cap, and
/// which rows have a motion.
private struct Reference {

    enum Presence {
        /// The sweep crosses P.
        case required
        /// The sweep only touches P's edge, within tolerance; SPEC doesn't say
        /// whether touching counts.
        case optional
        /// The sweep misses P.
        case forbidden
    }

    struct Motion {
        var kind: RowMotion.Kind
        var row: Int
        var naiveStartTop: CGFloat
        var naiveStartHeight: CGFloat
        var startTop: CGFloat
        var startHeight: CGFloat
        var endTop: CGFloat
        var endHeight: CGFloat
        var transition: RowTransition
        var presence = Presence.forbidden
        /// False for a removed row in a commit that doesn't animate: SPEC
        /// defines neither whether it has a motion nor its end.
        var valuesDefined = true
    }

    /// Why the case is skipped, when SPEC doesn't decide it.
    var ambiguity: String?
    var tolerance: CGFloat
    /// o', and o* before A7's clamp.
    var offset: CGFloat
    var unclampedOffset: CGFloat
    /// The restored anchor; `nil` when no row survived (A5 gives only the offset).
    var anchor: ScrollAnchor?
    /// A row anchor's row after the batch, and its screen top before it.
    var anchorRow: Int?
    var anchorStartTop: CGFloat = 0
    /// k (M7).
    var amplitude: CGFloat = 1
    /// A5's case where the anchor row was removed and no surviving row remains.
    var anchorWithoutSurvivor = false
    /// Which of M2's numbered fallbacks the inserted and removed rows took.
    var insertedRules = Set<Int>()
    var removedRules = Set<Int>()
    /// Some gap holds both removed and inserted rows.
    var hasMixedGap = false
    /// A8 after the commit; `nil` when W2's rescale lands within tolerance of the edge.
    var isFollowingTail: Bool?
    /// C: the height of U after the commit.
    var unobscuredHeight: CGFloat
    /// Every row that may have a motion, in the plan's order: surviving,
    /// inserted and moved rows by new index, then mounted removed rows by old index.
    var motions: [Motion] = []

    init(_ commit: Commit) {
        let oldHeights = commit.oldHeights
        let newHeights = commit.newHeights
        let oldTops = ReferenceGeometry.tops(heights: oldHeights, spacing: commit.oldSpacing)
        let newTops = ReferenceGeometry.tops(heights: newHeights, spacing: commit.newSpacing)
        let oldContent = ReferenceGeometry.contentHeight(heights: oldHeights, spacing: commit.oldSpacing)
        let newContent = ReferenceGeometry.contentHeight(heights: newHeights, spacing: commit.newSpacing)
        let tolerance = 1e-6 * max(1, oldContent, newContent)
        self.tolerance = tolerance
        let o = commit.oldViewport.offset
        let t = commit.oldViewport.insetTop
        let oldMax = max(-t, oldContent - commit.oldViewport.height + commit.oldViewport.insetBottom)
        let new = commit.newViewport
        let newMin = -new.insetTop
        let newMax = max(newMin, newContent - new.height + new.insetBottom)
        let oldCount = oldHeights.count
        let newCount = newHeights.count
        let slots = commit.slots
        var newIndexes = [Int?](repeating: nil, count: oldCount)
        for (row, slot) in slots.enumerated() {
            if let old = slot.old { newIndexes[old] = row }
        }
        /// M2's "surviving": not removed, and not moved.
        func survives(_ old: Int) -> Bool {
            guard let row = newIndexes[old] else { return false }
            return !slots[row].moved
        }

        // A1–A3.
        let resolved: ScrollAnchor
        switch commit.anchoring {
        case .automatic:
            if commit.followsTail, o >= oldMax - 1 {
                resolved = .tail
            } else if let row = oldHeights.indices.first(where: { oldTops[$0] + oldHeights[$0] > o + t }) {
                resolved = .row(row, distance: oldTops[row] - (o + t))
            } else {
                resolved = .offset(o)
            }
        case .row(let row):
            resolved = .row(row, distance: oldTops[row] - (o + t))
        case .scrollOffset:
            resolved = .offset(o)
        }

        // A4, A5, W2, then A6.
        let target: CGFloat
        switch resolved {
        case .tail:
            anchor = .tail
            target = newMax
        case .offset(let offset):
            anchor = .offset(offset)
            target = offset
        case .row(let row, var distance):
            var carrier: Int? = row
            if newIndexes[row] == nil {
                // A5: the first surviving (neither removed nor moved) row after
                // it, else the last before it, at its own pre-batch position.
                carrier = (row + 1..<oldCount).first(where: survives) ?? (0..<row).last(where: survives)
                if let carrier { distance = oldTops[carrier] - (o + t) }
            }
            if let carrier {
                let newRow = newIndexes[carrier]!
                if commit.rescalesAnchor { distance *= newHeights[newRow] / oldHeights[carrier] }
                anchor = .row(newRow, distance: distance)
                anchorRow = newRow
                anchorStartTop = oldTops[carrier] - o
                target = newTops[newRow] - new.insetTop - distance
            } else {
                // No surviving row remains: the offset, then A7.
                anchor = .offset(o)
                target = o
                anchorWithoutSurvivor = true
            }
        }
        unclampedOffset = target
        let offset = min(max(target, newMin), newMax)
        self.offset = offset

        // A8.
        if !commit.followsTail {
            isFollowingTail = false
        } else if commit.rescalesAnchor, abs(offset - (newMax - 1)) <= tolerance {
            isFollowingTail = nil
        } else {
            isFollowingTail = offset >= newMax - 1
        }

        // M2's gaps. Surviving rows (neither inserted, removed nor moved)
        // keep their order and cut both layouts into the same gaps: gap g lies
        // between the g-th and (g+1)-th surviving rows. A removed row's gap
        // counts the survivors before it in the old order; an inserted row's,
        // in the new order. Moved rows belong to no gap.
        var survivorsOld: [Int] = []
        var survivorsNew: [Int] = []
        for old in 0..<oldCount where survives(old) {
            survivorsOld.append(old)
            survivorsNew.append(newIndexes[old]!)
        }
        let gapCount = survivorsOld.count + 1
        var lastRemoved = [Int?](repeating: nil, count: gapCount)
        var firstInserted = [Int?](repeating: nil, count: gapCount)
        var removedGap = [Int](repeating: 0, count: oldCount)
        var insertedGap = [Int](repeating: 0, count: newCount)
        var gap = 0
        for old in 0..<oldCount {
            if survives(old) {
                gap += 1
            } else if newIndexes[old] == nil {
                removedGap[old] = gap
                lastRemoved[gap] = old
            }
        }
        gap = 0
        for row in 0..<newCount {
            if let old = slots[row].old {
                if !slots[row].moved { gap += 1 }
            } else {
                insertedGap[row] = gap
                if firstInserted[gap] == nil { firstInserted[gap] = row }
            }
        }
        hasMixedGap = (0..<gapCount).contains { lastRemoved[$0] != nil && firstInserted[$0] != nil }

        var naive: [Motion] = []
        for row in 0..<newCount {
            let slot = slots[row]
            let endTop = newTops[row] - offset
            let endHeight = newHeights[row]
            let kind: RowMotion.Kind
            let startTop: CGFloat
            let startHeight: CGFloat
            var transition: RowTransition = []
            if let old = slot.old {
                kind = slot.moved ? .moved : .surviving
                startTop = oldTops[old] - o
                startHeight = oldHeights[old]
            } else {
                // Inserted: height 0 where the gap's old contents end.
                kind = .inserted
                transition = slot.transition
                startHeight = 0
                let gap = insertedGap[row]
                if let removed = lastRemoved[gap] {
                    startTop = oldTops[removed] - o + oldHeights[removed] + commit.oldSpacing
                    insertedRules.insert(1)
                } else if gap > 0 {
                    let before = survivorsOld[gap - 1]
                    startTop = oldTops[before] - o + oldHeights[before] + commit.oldSpacing
                    insertedRules.insert(2)
                } else if gap < survivorsOld.count {
                    startTop = oldTops[survivorsOld[gap]] - o
                    insertedRules.insert(3)
                } else {
                    startTop = endTop
                    insertedRules.insert(4)
                }
            }
            naive.append(
                Motion(
                    kind: kind, row: row, naiveStartTop: startTop, naiveStartHeight: startHeight, startTop: startTop,
                    startHeight: startHeight, endTop: endTop, endHeight: endHeight, transition: transition))
        }
        for old in 0..<oldCount where newIndexes[old] == nil && commit.mounted.contains(old) {
            // Removed: height 0 where the gap's new contents begin.
            let startTop = oldTops[old] - o
            let gap = removedGap[old]
            let endTop: CGFloat
            if let inserted = firstInserted[gap] {
                endTop = newTops[inserted] - offset
                removedRules.insert(1)
            } else if gap > 0 {
                let before = survivorsNew[gap - 1]
                endTop = newTops[before] - offset + newHeights[before] + commit.newSpacing
                removedRules.insert(2)
            } else if gap < survivorsNew.count {
                endTop = newTops[survivorsNew[gap]] - offset
                removedRules.insert(3)
            } else {
                endTop = startTop
                removedRules.insert(4)
            }
            naive.append(
                Motion(
                    kind: .removed, row: old, naiveStartTop: startTop, naiveStartHeight: oldHeights[old],
                    startTop: startTop, startHeight: oldHeights[old], endTop: endTop, endHeight: 0,
                    transition: commit.removals[old] ?? []))
        }

        // M7 against P after the commit, in screen coordinates.
        let capacity = new.height - new.insetTop - new.insetBottom
        unobscuredHeight = capacity
        let preparedTop = new.insetTop - capacity / 2
        let preparedBottom = new.height - new.insetBottom + capacity / 2
        func presence(
            _ startTop: CGFloat, _ startHeight: CGFloat, _ endTop: CGFloat, _ endHeight: CGFloat
        )
            -> Presence
        {
            let top = min(startTop, endTop)
            let bottom = max(startTop + startHeight, endTop + endHeight)
            if top < preparedBottom - tolerance, bottom > preparedTop + tolerance { return .required }
            if top > preparedBottom + tolerance || bottom < preparedTop - tolerance { return .forbidden }
            return .optional
        }
        if commit.animates {
            func cap(_ motions: [Motion], counting: Set<Presence>) -> CGFloat {
                let largest =
                    motions.filter {
                        counting.contains(presence($0.naiveStartTop, $0.naiveStartHeight, $0.endTop, $0.endHeight))
                    }
                    .map { abs($0.naiveStartTop - $0.endTop) }.max() ?? 0
                return largest > capacity ? capacity / largest : 1
            }
            // M7's rows: those M2 gives values to (mounted removed rows only)
            // whose unscaled sweep meets P. "Meets" at a bare edge is left open.
            let definite = cap(naive, counting: [.required])
            if definite != cap(naive, counting: [.required, .optional]) {
                ambiguity = ambiguity ?? "M7: a row whose sweep only touches P sets k"
            }
            amplitude = definite
        }

        // The capped start, and which rows have a motion.
        let k = amplitude
        motions = naive.map { motion in
            var motion = motion
            if commit.animates {
                motion.startTop = motion.endTop + k * (motion.naiveStartTop - motion.endTop)
                motion.startHeight = motion.endHeight + k * (motion.naiveStartHeight - motion.endHeight)
            } else {
                motion.startTop = motion.endTop
                motion.startHeight = motion.endHeight
                motion.naiveStartTop = motion.endTop
                motion.naiveStartHeight = motion.endHeight
                motion.transition = []
            }
            motion.presence = presence(motion.startTop, motion.startHeight, motion.endTop, motion.endHeight)
            if !commit.animates, motion.kind == .removed {
                motion.presence = .optional
                motion.valuesDefined = false
            }
            return motion
        }
    }

    /// Everything M2 and §6 decide, compared with the plan.
    func mismatch(_ plan: CommitPlan, _ commit: Commit) -> String? {
        if plan.heights != RowHeights(commit.newHeights, spacing: commit.newSpacing) {
            return "plan.heights isn't the input's new heights"
        }
        if abs(plan.offset - offset) > tolerance {
            return "offset \(plan.offset), expected \(offset) (unclamped \(unclampedOffset))"
        }
        if abs(plan.amplitude - amplitude) > 1e-9 {
            return "amplitude \(plan.amplitude), expected \(amplitude)"
        }
        if let isFollowingTail, plan.isFollowingTail != isFollowingTail {
            return "isFollowingTail \(plan.isFollowingTail), expected \(isFollowingTail)"
        }
        // "The anchor as restored" is only unambiguous when nothing clamped.
        if let anchor, offset == unclampedOffset {
            switch (plan.anchor, anchor) {
            case (.tail, .tail):
                break
            case (.row(let row, let distance), .row(let expectedRow, let expectedDistance))
            where row == expectedRow && abs(distance - expectedDistance) <= tolerance:
                break
            case (.offset(let offset), .offset(let expectedOffset)) where abs(offset - expectedOffset) <= tolerance:
                break
            default:
                return "anchor \(plan.anchor), expected \(anchor)"
            }
        }

        var lookup: [Key: Motion] = [:]
        for motion in motions { lookup[Key(motion.kind, motion.row)] = motion }
        var seen = Set<Key>()
        var previous: Key? = nil
        for planned in plan.motions {
            let key = Key(planned)
            if let previous {
                let ordered = previous.removed == key.removed ? previous.row < key.row : !previous.removed
                if !ordered { return "motions out of order: \(previous) before \(key)" }
            }
            previous = key
            guard let expected = lookup[key] else { return "a motion that shouldn't exist: \(planned)" }
            if planned.kind != expected.kind { return "\(planned) should be \(expected.kind)" }
            if expected.presence == .forbidden {
                return "\(planned): its sweep misses P, so it has no motion (expected \(expected))"
            }
            if expected.valuesDefined {
                let values: [(String, CGFloat, CGFloat)] = [
                    ("startTop", planned.startTop, expected.startTop),
                    ("endTop", planned.endTop, expected.endTop),
                    ("startHeight", planned.startHeight, expected.startHeight),
                    ("endHeight", planned.endHeight, expected.endHeight),
                ]
                for (name, value, want) in values where abs(value - want) > tolerance {
                    return "\(planned): \(name) \(value), expected \(want) (expected \(expected))"
                }
                if planned.transition != expected.transition {
                    return "\(planned): transition \(planned.transition), expected \(expected.transition)"
                }
            } else if abs(planned.startTop - planned.endTop) > tolerance
                || abs(planned.startHeight - planned.endHeight) > tolerance || planned.transition != []
            {
                return "\(planned): a commit that doesn't animate has start equal to end and no transition"
            }
            seen.insert(key)
        }
        if let missing = motions.first(where: { $0.presence == .required && !seen.contains(Key($0.kind, $0.row)) }) {
            return "no motion for \(missing.kind) row \(missing.row), whose sweep crosses P: \(missing)"
        }
        return nil
    }
}

/// M5's presented order: the surviving rows in order, with each gap's
/// removed rows (old order) and then its inserted rows (new order) between
/// them, keeping only rows that have a motion. Moved rows are not in it.
private struct PresentedOrder {

    struct Item {
        var key: Key
        var survivor: (old: Int, new: Int)?
    }

    var items: [Item] = []

    init(_ commit: Commit, planned: Set<Key>) {
        var newIndexes = [Int?](repeating: nil, count: commit.oldHeights.count)
        for (row, slot) in commit.slots.enumerated() {
            if let old = slot.old { newIndexes[old] = row }
        }
        var survivors: [(old: Int, new: Int)] = []
        var inserted: [[Int]] = [[]]
        for (row, slot) in commit.slots.enumerated() {
            if let old = slot.old {
                if !slot.moved {
                    survivors.append((old, row))
                    inserted.append([])
                }
            } else {
                inserted[inserted.count - 1].append(row)
            }
        }
        var removed: [[Int]] = [[]]
        for old in 0..<commit.oldHeights.count {
            if let row = newIndexes[old] {
                if !commit.slots[row].moved { removed.append([]) }
            } else {
                removed[removed.count - 1].append(old)
            }
        }
        for gap in 0...survivors.count {
            let keys = removed[gap].map { Key(.removed, $0) } + inserted[gap].map { Key(.inserted, $0) }
            for key in keys where planned.contains(key) { items.append(Item(key: key)) }
            if gap < survivors.count {
                let survivor = survivors[gap]
                let key = Key(.surviving, survivor.new)
                if planned.contains(key) { items.append(Item(key: key, survivor: survivor)) }
            }
        }
    }
}

/// What the generator reached, and what was skipped as ambiguous.
private struct Tally {
    var checked = 0
    var skipped: [String: Int] = [:]
    var motions: [String: Int] = [:]

    mutating func skip(_ reason: String) {
        skipped[reason, default: 0] += 1
    }

    mutating func record(_ commit: Commit, _ reference: Reference, _ plan: CommitPlan) {
        checked += 1
        for motion in plan.motions { motions["\(motion.kind)", default: 0] += 1 }
        if reference.amplitude < 1 { motions["capped commits", default: 0] += 1 }
        if reference.offset != reference.unclampedOffset { motions["clamped commits", default: 0] += 1 }
        if reference.hasMixedGap { motions["gap with removed and inserted rows", default: 0] += 1 }
        if reference.anchorWithoutSurvivor { motions["A5 anchor with no survivor", default: 0] += 1 }
        let oldRowRemains = commit.slots.contains { $0.old != nil }
        if !commit.oldHeights.isEmpty, !oldRowRemains, !commit.slots.isEmpty {
            motions["every old row removed, rows inserted", default: 0] += 1
        }
        if !commit.slots.isEmpty, commit.slots.allSatisfy({ $0.old == nil || $0.moved }),
            commit.slots.contains(where: { $0.old != nil })
        {
            motions["every remaining row moved", default: 0] += 1
        }
        for rule in reference.insertedRules { motions["inserted rule \(rule)", default: 0] += 1 }
        for rule in reference.removedRules { motions["removed rule \(rule)", default: 0] += 1 }
    }

    func assertCoverage(checked minimum: Int, motions minimums: [String: Int]) {
        XCTAssertGreaterThan(checked, minimum, "skipped \(skipped)")
        for (kind, least) in minimums {
            XCTAssertGreaterThan(motions[kind, default: 0], least, "rarely generated: \(kind) in \(motions)")
        }
        assertFewSkips()
    }

    func assertFewSkips() {
        XCTAssertLessThan(skipped.values.reduce(0, +), 1500, "too many cases skipped as ambiguous: \(skipped)")
    }
}
