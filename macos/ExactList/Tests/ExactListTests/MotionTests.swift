import ExactListTestSupport
import XCTest

@testable import ExactList

/// Motion frame by frame, from presentation layers: §8.
///
/// A commit is sampled on every display refresh until its motion ends. At each
/// sample `p` is read off the row that moves farthest, and every other row
/// must be where M2 puts it at that `p` (SPEC §13).
///
/// Each method proves the requirement in its name. `SpecCoverageTests` checks
/// that every ID in `SPEC.md` has one.
@MainActor
final class MotionTests: XCTestCase {

    /// Outside any group, an update animates as `NSTableView`'s do, for 0.2 s
    /// with `.easeOut`, checked against the curve's own control points; a
    /// group's duration is what it uses, with `.default` for a `nil` timing
    /// function, and a group's timing function is what it uses; its completion
    /// handler runs once the motion has ended; a duration-0 group,
    /// `reloadData()`, a width change and a scroll request without implicit
    /// animation move nothing, even inside a group that allows implicit
    /// animation. A batch that asks for no motion moves nothing: an insert or
    /// a removal with no effect, even in a group, and a noted row whose height
    /// is unchanged; with implicit animation allowed it takes the group's
    /// timing. A move takes 0.4 s outside a group. Reduce Motion: the branch
    /// this machine is in (§13).
    func testM1_whichCommitsAnimate() async throws {
        guard #available(macOS 14, *) else { throw XCTSkip("the display link needs macOS 14") }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        var heights: [CGFloat] = Array(repeating: 30, count: 200)
        let host = RecordingHost(count: heights.count) { row, _ in heights[row] }
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)
        list.scrollToRow(20, at: .top)
        await stage.settle()

        // Outside any group: 0.2 s, ease out. Row 22 opens under
        // row 21, and the rows below it move down.
        var old = ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)
        heights.insert(45, at: 22)
        host.count = heights.count
        list.performBatchUpdates(anchoring: .scrollOffset) { $0.insertRows(at: [22], withAnimation: .effectGap) }
        var new = ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)
        if reduceMotion {
            try assertStill(list, heights: heights, "Reduce Motion is on: nothing moves")
        } else {
            var rows = try (23..<29).map {
                Moving(try container(ofRow: $0, in: list), old[$0 - 1], new[$0], at: 600, label: "row \($0)")
            }
            rows.append(
                Moving(
                    try container(ofRow: 22, in: list), CGRect(x: 0, y: old[21].maxY, width: 1, height: 0), new[22],
                    at: 600, label: "inserted"))
            assertAtStart(rows, in: list)
            let timeline = progress(of: rows, in: await record(rows, in: list, for: 0.4))
            assertTimeline(timeline, duration: 0.2, curve: Self.bezier(0, 0, 0.58, 1), "outside any group")
        }
        _ = await stage.drain(until: { self.clocks(in: list) == 0 }, timeout: 2)

        // A group that sets nothing: its own 0.25 s and `.default`, as in
        // NSTableView, though the context reads as it does outside one.
        old = ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)
        NSAnimationContext.runAnimationGroup { _ in
            heights[24] = 50
            list.noteHeightOfRows(withIndexesChanged: [24])
        } completionHandler: {
        }
        new = ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)
        if !reduceMotion {
            let rows = try (24..<29).map {
                Moving(try container(ofRow: $0, in: list), old[$0], new[$0], at: 600, label: "row \($0)")
            }
            let timeline = progress(of: rows, in: await record(rows, in: list, for: 0.4))
            assertTimeline(
                timeline, duration: 0.25, curve: Self.bezier(0.25, 0.1, 0.25, 1), "a group that sets nothing")
        }
        _ = await stage.drain(until: { self.clocks(in: list) == 0 }, timeout: 2)

        // A group's own duration and timing, and its completion after the
        // motion.
        old = ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)
        var groupEnded: TimeInterval?
        var motionEnded: TimeInterval?
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.6
            heights[23] = 70
            list.performBatchUpdates({ $0.noteHeightOfRows(withIndexesChanged: [23]) }) { _ in
                motionEnded = CACurrentMediaTime()
            }
        } completionHandler: {
            groupEnded = CACurrentMediaTime()
        }
        new = ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)
        if reduceMotion {
            try assertStill(list, heights: heights, "Reduce Motion is on: nothing moves")
        } else {
            let rows = try (23..<29).map {
                Moving(try container(ofRow: $0, in: list), old[$0], new[$0], at: 600, label: "row \($0)")
            }
            assertAtStart(rows, in: list)
            let timeline = progress(of: rows, in: await record(rows, in: list, for: 0.8))
            assertTimeline(
                timeline, duration: 0.6, curve: Self.bezier(0.25, 0.1, 0.25, 1), "a group's duration, .default")
            _ = await stage.drain(until: { groupEnded != nil }, timeout: 2)
            let ended = try XCTUnwrap(groupEnded, "the group's completion handler ran")
            let landed = try XCTUnwrap(motionEnded, "the motion ended first")
            XCTAssertGreaterThanOrEqual(ended, landed, "the group waits for the motion")
        }
        _ = await stage.drain(until: { self.clocks(in: list) == 0 }, timeout: 2)

        // A duration-0 group turns animation off.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            heights.remove(at: 21)
            host.count = heights.count
            list.removeRows(at: [21], withAnimation: .effectFade)
        } completionHandler: {
        }
        try assertStill(list, heights: heights, "duration 0")

        // reloadData and a width change never animate, even with implicit
        // animation allowed; nor does a scroll request without it.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.5
            context.allowsImplicitAnimation = true
            heights[22] = 90
            list.reloadData()
        } completionHandler: {
        }
        try assertStill(list, heights: heights, "reloadData()")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.5
            context.allowsImplicitAnimation = true
            stage.window.setContentSize(NSSize(width: 330, height: 300))
            stage.window.layoutIfNeeded()
        } completionHandler: {
        }
        XCTAssertEqual(list.rect(ofRow: 22).width, try documentView(of: list).bounds.width)
        try assertStill(list, heights: heights, "a width change")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.5
            list.scrollToRow(120, at: .top)
        } completionHandler: {
        }
        XCTAssertEqual(offset(of: list), ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)[120].minY)
        try assertStill(list, heights: heights, "a scroll request without implicit animation")

        // No effect asks for no motion, as in NSTableView: outside a group, in
        // one, and with a noted row whose height is the same.
        heights.insert(30, at: 122)
        host.count = heights.count
        list.insertRows(at: [122])
        try assertStill(list, heights: heights, "an insert with no effect")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.5
            heights.remove(at: 122)
            host.count = heights.count
            list.removeRows(at: [122])
        } completionHandler: {
        }
        try assertStill(list, heights: heights, "a removal with no effect, in a group")
        heights.insert(30, at: 122)
        host.count = heights.count
        list.performBatchUpdates {
            $0.insertRows(at: [122])
            $0.noteHeightOfRows(withIndexesChanged: [125])
        }
        try assertStill(list, heights: heights, "and a noted row whose height is the same")

        // With implicit animation allowed, the group's timing.
        var o = offset(of: list)
        old = ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.allowsImplicitAnimation = true
            heights.insert(45, at: 122)
            host.count = heights.count
            list.performBatchUpdates(anchoring: .scrollOffset) { $0.insertRows(at: [122]) }
        } completionHandler: {
        }
        new = ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)
        if !reduceMotion {
            let rows = try (123..<128).map {
                Moving(try container(ofRow: $0, in: list), old[$0 - 1], new[$0], at: o, label: "row \($0)")
            }
            let timeline = progress(of: rows, in: await record(rows, in: list, for: 0.5))
            assertTimeline(
                timeline, duration: 0.3, curve: Self.bezier(0.25, 0.1, 0.25, 1), "no effect, implicit animation")
        }
        _ = await stage.drain(until: { self.clocks(in: list) == 0 }, timeout: 2)

        // A move, outside any group: 0.4 s, ease out.
        o = offset(of: list)
        old = ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)
        heights.insert(heights.remove(at: 121), at: 126)
        list.performBatchUpdates(anchoring: .scrollOffset) { $0.moveRow(at: 121, to: 126) }
        new = ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)
        if reduceMotion {
            try assertStill(list, heights: heights, "Reduce Motion is on: nothing moves")
        } else {
            var rows = try (121..<126).map {
                Moving(try container(ofRow: $0, in: list), old[$0 + 1], new[$0], at: o, label: "row \($0)")
            }
            rows.append(Moving(try container(ofRow: 126, in: list), old[121], new[126], at: o, label: "moved"))
            let timeline = progress(of: rows, in: await record(rows, in: list, for: 0.6))
            assertTimeline(timeline, duration: 0.4, curve: Self.bezier(0, 0, 0.58, 1), "a move, outside any group")
        }
        _ = await stage.drain(until: { self.clocks(in: list) == 0 }, timeout: 2)
    }

    /// With linear timing, sampled on every refresh: the model is at the start
    /// when the commit returns, and final once the motion ends; at every
    /// sample each row is where M2 puts it at one `p`, its hosted view fills
    /// it, and every row inside the viewport has a non-empty `visibleRect`;
    /// no layer carries a CoreAnimation animation. First a height change
    /// alone, then a batch with an insert, a removal and a noted row.
    func testM3_howItIsDone() async throws {
        guard #available(macOS 14, *) else { throw XCTSkip("the display link needs macOS 14") }
        try XCTSkipIf(
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "Reduce Motion is on: nothing moves, as testM1 asserts (§13)")
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        var heights: [CGFloat] = Array(repeating: 30, count: 40)
        let host = RecordingHost(count: heights.count) { row, _ in heights[row] }
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)

        // A height change alone: row 5 from 30 to 60, row 0 held at the top.
        var old = ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)
        var finished = false
        heights[5] = 60
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 1
            context.timingFunction = CAMediaTimingFunction(name: .linear)
            list.performBatchUpdates({ $0.noteHeightOfRows(withIndexesChanged: [5]) }) { finished = $0 }
        } completionHandler: {
        }
        var new = ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)
        XCTAssertEqual(list.rect(ofRow: 0).minY, 0, "o is still 0")
        var rows = try (0..<10).map {
            Moving(try container(ofRow: $0, in: list), old[$0], new[$0], at: 0, label: "row \($0)")
        }
        assertAtStart(rows, in: list)
        var timeline = progress(of: rows, in: try await recordChecking(rows, in: list, for: 1.2))
        assertTimeline(timeline, duration: 1, curve: { $0 }, "a height change")
        _ = await stage.drain(until: { finished }, timeout: 3)
        XCTAssertTrue(finished)
        XCTAssertEqual(clocks(in: list), 0, "its clock is gone")

        // Insert at 8 (40 tall), remove old 12, note row 3 (to 45), in one batch.
        old = ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)
        let removedContainer = try container(ofRow: 12, in: list)
        let removedHost = try XCTUnwrap(list.view(atRow: 12))
        finished = false
        heights.remove(at: 12)
        heights.insert(40, at: 8)
        heights[3] = 45
        host.count = heights.count
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 1
            context.timingFunction = CAMediaTimingFunction(name: .linear)
            list.performBatchUpdates(
                {
                    $0.removeRows(at: [12])
                    $0.insertRows(at: [8])
                    $0.noteHeightOfRows(withIndexesChanged: [3])
                }, completionHandler: { finished = $0 })
        } completionHandler: {
        }
        new = ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)
        XCTAssertEqual(list.rect(ofRow: 0).minY, 0, "o is still 0")
        rows = []
        for newRow in 0..<11 where newRow != 8 {
            let oldRow = newRow < 8 ? newRow : newRow - 1
            rows.append(
                Moving(
                    try container(ofRow: newRow, in: list), old[oldRow], new[newRow], at: 0, label: "survivor \(oldRow)"
                ))
        }
        // Inserted: its gap (after old 7) has no removed row: rule 2.
        rows.append(
            Moving(
                try container(ofRow: 8, in: list), CGRect(x: 0, y: old[7].maxY, width: 1, height: 0), new[8], at: 0,
                label: "inserted"))
        // Removed: its gap (after old 11, now 12) has no inserted row: rule 2.
        rows.append(
            Moving(
                removedContainer, old[12], CGRect(x: 0, y: new[12].maxY, width: 1, height: 0), at: 0, label: "removed"))
        assertAtStart(rows, in: list)
        XCTAssertEqual(list.row(for: removedHost), -1, "animating out")
        timeline = progress(of: rows, in: try await recordChecking(rows, in: list, for: 1.2))
        assertTimeline(timeline, duration: 1, curve: { $0 }, "a batch")
        _ = await stage.drain(until: { finished }, timeout: 3)
        XCTAssertTrue(finished)
    }

    /// From the display link, frame by frame as shown: every point of `U`
    /// between the content's presented edges is in a presented row or in a
    /// gap of at most `s`. A removal mid-viewport, a tall insert, a removal
    /// at the tail (clamped, A7), a removal and insert sharing a gap with
    /// spacing, and a long animated scroll.
    func testM6_noBlankAreas() async throws {
        guard #available(macOS 14, *) else { throw XCTSkip("the display link needs macOS 14") }
        try XCTSkipIf(
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "Reduce Motion is on: nothing moves, as testM1 asserts (§13)")
        for scenario in BlankScenario.allCases {
            let stage = ListStage(size: NSSize(width: 400, height: 300))
            defer { stage.teardown() }
            let spacing: CGFloat = scenario == .sharedGapWithSpacing ? 6 : 0
            var heights: [CGFloat] = (0..<2000).map { 22 + CGFloat(($0 * 17) % 31) }
            let host = RecordingHost(count: heights.count) { row, _ in heights[row] }
            let list = ExactListView(dataSource: host, delegate: host)
            list.rowSpacing = spacing
            await stage.mount(list)
            list.scrollToRow(scenario == .tailRemoval ? heights.count - 1 : 300, at: .top)
            await stage.settle()
            let first = list.rows(in: list.bounds).lowerBound

            var finished = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                context.allowsImplicitAnimation = scenario == .longScroll
                switch scenario {
                case .midRemoval:
                    heights.removeSubrange(first + 3..<first + 6)
                    host.count = heights.count
                    list.performBatchUpdates({
                        $0.removeRows(at: IndexSet(first + 3..<first + 6), withAnimation: .effectGap)
                    }) {
                        finished = $0
                    }
                case .tallInsert:
                    heights.insert(250, at: first + 2)
                    host.count = heights.count
                    list.performBatchUpdates({ $0.insertRows(at: [first + 2], withAnimation: .effectGap) }) {
                        finished = $0
                    }
                case .tailRemoval:
                    heights.removeLast(5)
                    host.count = heights.count
                    list.performBatchUpdates({
                        $0.removeRows(at: IndexSet(heights.count..<heights.count + 5), withAnimation: .effectGap)
                    }) { finished = $0 }
                case .sharedGapWithSpacing:
                    heights.remove(at: first + 4)
                    heights.insert(contentsOf: [70, 20], at: first + 4)
                    host.count = heights.count
                    list.performBatchUpdates({
                        $0.removeRows(at: [first + 4], withAnimation: .effectGap)
                        $0.insertRows(at: [first + 4, first + 5], withAnimation: .effectGap)
                    }) { finished = $0 }
                case .longScroll:
                    list.scrollToRow(1500, at: .top)
                    finished = true
                }
            } completionHandler: {
            }

            // Hidden containers are spares in no row (P3): they show nothing.
            // A scroll mounts rows as it goes, so every sample reads them anew.
            let document = try documentView(of: list)
            let rowsAtCommit = Set(
                document.subviews.compactMap { $0 as? RowContainerView }.filter { !$0.isHidden }.map(\.row))
            let edgeTop = rowsAtCommit.contains(0)
            let edgeBottom = rowsAtCommit.contains(heights.count - 1)
            let frames = await PresentationSampler.record(in: list, for: 0.45) {
                document.subviews.compactMap { $0 as? RowContainerView }
            }
            XCTAssertGreaterThan(frames.count, 10, "\(scenario): sampled the animation")
            let top = list.contentInsets.top
            let bottom = list.bounds.height - list.contentInsets.bottom
            for frame in frames {
                let rects = frame.frames.values.filter { $0.height > 0 }
                let lower = max(top, edgeTop ? rects.map(\.minY).min() ?? top : top)
                let upper = min(bottom, edgeBottom ? rects.map(\.maxY).max() ?? bottom : bottom)
                if let hole = firstHole(in: rects, from: lower, to: upper, tolerance: spacing + 1e-3) {
                    XCTFail("\(scenario) at \(frame.elapsed) s: blank at y \(hole)")
                    break
                }
            }
            _ = await stage.drain(until: { finished }, timeout: 3)
        }
    }

    /// A second commit in the middle of a first one, both linear: nothing
    /// moves at that moment (C0); the first motion carries on, and the second
    /// runs on a clock of its own; at every sample each row is its final frame
    /// plus the remaining part of both motions, with `p` read off the second
    /// commit's anchor, which only the first moves, and a row both move; both
    /// land on the end layout and complete.
    func testM8_interruptionsCompose() async throws {
        guard #available(macOS 14, *) else { throw XCTSkip("the display link needs macOS 14") }
        try XCTSkipIf(
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "Reduce Motion is on: nothing moves, as testM1 asserts (§13)")
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        var heights: [CGFloat] = Array(repeating: 30, count: 60)
        let host = RecordingHost(count: heights.count) { row, _ in heights[row] }
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)
        list.scrollToRow(10, at: .top)
        await stage.settle()
        let linear = CAMediaTimingFunction(name: .linear)

        // A: two rows above the viewport, the offset held: rows slide down 100.
        let f0 = ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)
        var firstDone: Bool?
        heights.insert(contentsOf: [50, 50], at: 3)
        host.count = heights.count
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 1
            context.timingFunction = linear
            list.performBatchUpdates(
                anchoring: .scrollOffset, { $0.insertRows(at: [3, 4], withAnimation: .effectGap) }
            ) {
                firstDone = $0
            }
        } completionHandler: {
        }
        let f1 = ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)
        let watched = try (12..<20).map { try container(ofRow: $0, in: list) }
        _ = await stage.drain(until: { false }, timeout: 0.4)
        XCTAssertNil(firstDone, "A is still moving")
        let before = watched.map { list.convert($0.bounds, from: $0) }

        // B, in the middle of A: one row above row 14, which is held.
        var secondDone: Bool?
        heights.insert(40, at: 13)
        host.count = heights.count
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 1
            context.timingFunction = linear
            list.performBatchUpdates(anchoring: .row(14), { $0.insertRows(at: [13], withAnimation: .effectGap) }) {
                secondDone = $0
            }
        } completionHandler: {
        }
        let f2 = ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)
        XCTAssertEqual(offset(of: list), 340, "B's offset: the anchor held")
        for (index, view) in watched.enumerated() {
            let now = list.convert(view.bounds, from: view)
            XCTAssertEqual(now.minY, before[index].minY, accuracy: 1e-9, "row \(12 + index): C0 at B")
            XCTAssertEqual(now.height, before[index].height, accuracy: 1e-9)
        }

        // Row 12 + i after A was 10 + i before it, and is 12 + i after B if
        // it is above B's insert, else 13 + i. Each row's screen top is B's
        // end plus A's remaining part plus B's.
        struct Composed {
            let view: NSView
            let end: CGFloat
            let a: CGFloat
            let b: CGFloat
        }
        let composed = watched.enumerated().map { index, view in
            let afterA = 12 + index
            let afterB = afterA < 13 ? afterA : afterA + 1
            return Composed(
                view: view, end: f2[afterB].minY - 340, a: (f0[10 + index].minY - 300) - (f1[afterA].minY - 300),
                b: (f1[afterA].minY - 300) - (f2[afterB].minY - 340))
        }
        let anchor = composed[2]
        let both = composed[0]
        XCTAssertEqual(anchor.b, 0, "B's anchor has no motion of B's")
        XCTAssertNotEqual(both.b, 0)
        let samples = await PresentationSampler.record(watched, in: list, for: 1.2)
        var pA: [CGFloat] = []
        var pB: [CGFloat] = []
        for sample in samples {
            guard let anchorTop = sample.frames[ObjectIdentifier(anchor.view)]?.minY,
                let bothTop = sample.frames[ObjectIdentifier(both.view)]?.minY
            else { continue }
            let a = 1 - (anchorTop - anchor.end) / anchor.a
            let b = 1 - (bothTop - both.end - both.a * (1 - a)) / both.b
            pA.append(a)
            pB.append(b)
            for row in composed {
                guard let top = sample.frames[ObjectIdentifier(row.view)]?.minY else { continue }
                XCTAssertEqual(
                    top, row.end + row.a * (1 - a) + row.b * (1 - b), accuracy: Self.accuracy,
                    "at \(sample.elapsed) s: A and B add up")
            }
        }
        XCTAssertGreaterThan(pA.count, 20, "sampled both motions")
        XCTAssertEqual(pA.last ?? 0, 1, accuracy: 1e-6, "A ends")
        XCTAssertEqual(pB.last ?? 0, 1, accuracy: 1e-6, "B ends")
        XCTAssertGreaterThan(pA.first ?? 0, pB.first ?? 1, "A started first")
        for index in pA.indices.dropFirst() {
            XCTAssertGreaterThanOrEqual(pA[index], pA[index - 1] - 1e-6, "A's p never decreases")
            XCTAssertGreaterThanOrEqual(pB[index], pB[index - 1] - 1e-6, "B's p never decreases")
        }
        _ = await stage.drain(until: { firstDone != nil && secondDone != nil }, timeout: 3)
        XCTAssertEqual(firstDone, true)
        XCTAssertEqual(secondDone, true)
    }

    /// Each effect, inserted and removed, with linear timing: at every sample,
    /// the container's presented opacity for a fade, and the hosted view's
    /// offset inside its container for a slide, in screen coordinates, at the
    /// `p` the moving rows give. No effect is checked in a batch that animates
    /// for a height change further down.
    func testM9_effects() async throws {
        guard #available(macOS 14, *) else { throw XCTSkip("the display link needs macOS 14") }
        try XCTSkipIf(
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "Reduce Motion is on: nothing moves, as testM1 asserts (§13)")
        let options: [(NSTableView.AnimationOptions, String)] = [
            ([], "none"), (.effectGap, "gap"), (.effectFade, "fade"), (.slideUp, "slideUp"),
            (.slideDown, "slideDown"), (.slideLeft, "slideLeft"), (.slideRight, "slideRight"),
        ]
        for (option, name) in options {
            let stage = ListStage(size: NSSize(width: 400, height: 300))
            defer { stage.teardown() }
            var heights: [CGFloat] = Array(repeating: 30, count: 40)
            let host = RecordingHost(count: heights.count) { row, _ in heights[row] }
            let list = ExactListView(dataSource: host, delegate: host)
            await stage.mount(list)
            let width = try documentView(of: list).bounds.width

            for inserting in [true, false] {
                let phase = "\(name) \(inserting ? "insert" : "remove")"
                let old = ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)
                var done = false
                let removing = inserting ? nil : try container(ofRow: 3, in: list)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 1
                    context.timingFunction = CAMediaTimingFunction(name: .linear)
                    if inserting {
                        heights.insert(50, at: 3)
                        host.count = heights.count
                        heights[30] += 5
                        list.performBatchUpdates(
                            {
                                $0.insertRows(at: [3], withAnimation: option)
                                $0.noteHeightOfRows(withIndexesChanged: [30])
                            }, completionHandler: { done = $0 })
                    } else {
                        heights.remove(at: 3)
                        host.count = heights.count
                        heights[30] += 5
                        list.performBatchUpdates(
                            {
                                $0.removeRows(at: [3], withAnimation: option)
                                $0.noteHeightOfRows(withIndexesChanged: [30])
                            }, completionHandler: { done = $0 })
                    }
                } completionHandler: {
                }
                let new = ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)
                let effectedRow = try removing ?? container(ofRow: 3, in: list)
                let hosted = try XCTUnwrap(effectedRow.hostedView, phase)
                var rows = try (4..<9).map {
                    let oldRow = inserting ? $0 - 1 : $0 + 1
                    let newRow = $0
                    return Moving(
                        try container(ofRow: newRow, in: list), old[oldRow], new[newRow], at: 0, label: "row \(newRow)")
                }
                let gap = CGRect(x: 0, y: old[2].maxY, width: 1, height: 0)
                var row = Moving(
                    effectedRow, inserting ? gap : old[3], inserting ? new[3] : gap, at: 0, label: phase)
                row.contentStill = false
                rows.append(row)
                let samples = await PresentationSampler.record(
                    rows.map(\.view) + [hosted], in: list, for: 1.2)
                for (sample, p) in progress(of: rows, in: samples) {
                    guard let clip = sample.frames[ObjectIdentifier(effectedRow)],
                        let content = sample.frames[ObjectIdentifier(hosted)]
                    else { continue }
                    let at = "\(phase) at \(sample.elapsed) s, p \(p)"
                    let shown = inserting ? p : 1 - p
                    let away = inserting ? 1 - p : p
                    let sign: CGFloat = inserting ? 1 : -1
                    var expectedX: CGFloat = 0
                    var expectedY: CGFloat = 0
                    if option == .slideUp { expectedY = sign * 50 * away }
                    if option == .slideDown { expectedY = -sign * 50 * away }
                    if option == .slideLeft { expectedX = sign * width * away }
                    if option == .slideRight { expectedX = -sign * width * away }
                    XCTAssertEqual(content.minX - clip.minX, expectedX, accuracy: Self.accuracy, "\(at): horizontal")
                    XCTAssertEqual(content.minY - clip.minY, expectedY, accuracy: Self.accuracy, "\(at): vertical")
                    XCTAssertEqual(content.height, clip.height, accuracy: Self.accuracy, "\(at): fills its container")
                    let opacity = try XCTUnwrap(sample.opacities[ObjectIdentifier(effectedRow)])
                    let expected: CGFloat = option.contains(.effectFade) ? shown : 1
                    XCTAssertEqual(opacity, expected, accuracy: 1e-4, "\(at): opacity")
                }
                _ = await stage.drain(until: { done }, timeout: 3)
                XCTAssertTrue(done, phase)
            }
        }
    }

    /// A move and a removal in one batch: the moved container is drawn above
    /// every other and travels straight; the removed one is drawn below every
    /// other, closes its slot, and stays mounted until its motion ends, when
    /// its host hears `didRemove` with row −1.
    func testM10_stackingOrder() async throws {
        guard #available(macOS 14, *) else { throw XCTSkip("the display link needs macOS 14") }
        try XCTSkipIf(
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "Reduce Motion is on: nothing moves, as testM1 asserts (§13)")
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        var heights: [CGFloat] = (0..<30).map { 30 + CGFloat($0 % 3) * 10 }
        let host = RecordingHost(count: heights.count) { row, _ in heights[row] }
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)
        let document = try documentView(of: list)
        let old = ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)
        let movedContainer = try container(ofRow: 2, in: list)
        let removedContainer = try container(ofRow: 9, in: list)
        let removedView = try XCTUnwrap(list.view(atRow: 9))
        let survivorsBefore = try [0, 1, 3, 4, 5, 6, 7, 8, 10].map { ($0, try container(ofRow: $0, in: list)) }

        // Move 2 to 6, then remove the row now at 9 (old 9): new order is
        // 0 1 3 4 5 6 2 7 8 10 …
        var done = false
        let moved = heights.remove(at: 2)
        heights.insert(moved, at: 6)
        heights.remove(at: 9)
        host.count = heights.count
        host.resetCalls()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 1
            context.timingFunction = CAMediaTimingFunction(name: .linear)
            list.performBatchUpdates(
                {
                    $0.moveRow(at: 2, to: 6)
                    $0.removeRows(at: [9])
                }, completionHandler: { done = $0 })
        } completionHandler: {
        }
        let new = ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)
        let newIndex = [0: 0, 1: 1, 3: 2, 4: 3, 5: 4, 6: 5, 7: 7, 8: 8, 10: 9]

        let stack = document.subviews.compactMap { $0 as? RowContainerView }.filter { !$0.isHidden }
        XCTAssertTrue(stack.last === movedContainer, "the moved row is drawn above the others")
        XCTAssertTrue(stack.first === removedContainer, "the removed row is drawn below the others")

        var rows = [
            Moving(movedContainer, old[2], new[6], at: 0, label: "moved"),
            Moving(
                removedContainer, old[9], CGRect(x: 0, y: new[8].maxY, width: 1, height: 0), at: 0, label: "removed"),
        ]
        for (oldRow, view) in survivorsBefore {
            rows.append(Moving(view, old[oldRow], new[newIndex[oldRow]!], at: 0, label: "survivor \(oldRow)"))
        }
        assertAtStart(rows, in: list)
        XCTAssertNotNil(removedView.window, "still mounted while it moves")
        XCTAssertEqual(list.row(for: removedView), -1)
        let samples = await record(rows, in: list, for: 0.7)
        XCTAssertFalse(host.calls.contains(.didRemove(ObjectIdentifier(removedView), row: -1)), "not yet removed")
        XCTAssertTrue(
            samples.allSatisfy { $0.frames[ObjectIdentifier(removedContainer)] != nil }, "shown while it moves")
        _ = progress(of: rows, in: samples, ends: false)

        _ = await stage.drain(until: { done }, timeout: 3)
        XCTAssertTrue(done)
        XCTAssertTrue(
            host.calls.contains(.didRemove(ObjectIdentifier(removedView), row: -1)), "didRemove with −1 once it ends")
    }

    // MARK: - Helpers

    /// Presented geometry is the model the clock set, read back through
    /// CoreAnimation's layer geometry: far below a pixel.
    private static let accuracy: CGFloat = 0.01

    private enum BlankScenario: CaseIterable {
        case midRemoval, tallInsert, tailRemoval, sharedGapWithSpacing, longScroll
    }

    /// A row in one commit's motion: its container, and its start and end in
    /// the list's coordinates, from the test's own document frames and the
    /// offset `o` the commit held.
    private struct Moving {
        let view: RowContainerView
        let start: CGRect
        let end: CGRect
        let label: String
        /// The hosted view sits at the container's top at every sample. A row
        /// with a slide is checked by its own test (M9).
        var contentStill = true

        init(_ view: RowContainerView, _ start: CGRect, _ end: CGRect, at offset: CGFloat, label: String) {
            self.view = view
            self.start = start.offsetBy(dx: 0, dy: -offset)
            self.end = end.offsetBy(dx: 0, dy: -offset)
            self.label = label
        }

        /// How far it moves, by top or by height.
        var spread: CGFloat { max(abs(start.minY - end.minY), abs(start.height - end.height)) }

        /// Where M2 puts it at `p`.
        func at(_ p: CGFloat) -> (top: CGFloat, height: CGFloat) {
            (end.minY + (start.minY - end.minY) * (1 - p), end.height + (start.height - end.height) * (1 - p))
        }

        /// The `p` its presented frame gives.
        func progress(of frame: CGRect) -> CGFloat {
            abs(start.minY - end.minY) >= abs(start.height - end.height)
                ? 1 - (frame.minY - end.minY) / (start.minY - end.minY)
                : 1 - (frame.height - end.height) / (start.height - end.height)
        }
    }

    private func documentView(of list: ExactListView) throws -> NSView {
        try XCTUnwrap(list.subviews.compactMap { $0 as? NSScrollView }.first?.documentView)
    }

    private func container(ofRow row: Int, in list: ExactListView) throws -> RowContainerView {
        try XCTUnwrap(list.view(atRow: row)?.superview as? RowContainerView, "row \(row) is mounted")
    }

    /// `o` from where row 0 is.
    private func offset(of list: ExactListView) -> CGFloat {
        -list.rect(ofRow: 0).minY
    }

    /// The motion clocks running in the list.
    private func clocks(in list: ExactListView) -> Int {
        ((try? documentView(of: list))?.subviews ?? []).filter { $0 is MotionClock }.count
    }

    /// Every CoreAnimation animation on every container and hosted view.
    private func animationKeys(_ list: ExactListView) -> [String] {
        guard let document = try? documentView(of: list) else { return [] }
        var keys: [String] = []
        for case let container as RowContainerView in document.subviews {
            keys += (container.layer?.animationKeys() ?? []).map { "row \(container.row) container \($0)" }
            keys += (container.hostedView?.layer?.animationKeys() ?? []).map { "row \(container.row) host \($0)" }
        }
        return keys
    }

    /// Nothing moves: no clock runs, no layer animates, and every showing
    /// container is at its row's final frame from the test's own heights.
    private func assertStill(
        _ list: ExactListView, heights: [CGFloat], _ label: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertEqual(clocks(in: list), 0, "\(label): no clock", file: file, line: line)
        XCTAssertEqual(animationKeys(list), [], "\(label): no animation", file: file, line: line)
        let frames = ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)
        let o = offset(of: list)
        for case let container as RowContainerView in try documentView(of: list).subviews
        where !container.isHidden {
            XCTAssertGreaterThanOrEqual(container.row, 0, "\(label): nothing animating out", file: file, line: line)
            guard container.row >= 0 else { continue }
            let model = list.convert(container.bounds, from: container)
            XCTAssertEqual(
                model.minY, frames[container.row].minY - o, accuracy: 1e-9, "\(label): row \(container.row) top",
                file: file, line: line)
            XCTAssertEqual(
                model.height, frames[container.row].height, accuracy: 1e-9, "\(label): row \(container.row) height",
                file: file, line: line)
        }
    }

    /// U1, M3: when the commit returns, each row is at its start, as the
    /// model, and no layer animates.
    private func assertAtStart(
        _ rows: [Moving], in list: ExactListView, file: StaticString = #filePath, line: UInt = #line
    ) {
        for row in rows {
            let model = list.convert(row.view.bounds, from: row.view)
            XCTAssertEqual(
                model.minY, row.start.minY, accuracy: 1e-9, "\(row.label): at its start", file: file, line: line)
            XCTAssertEqual(
                model.height, row.start.height, accuracy: 1e-9, "\(row.label): at its start height", file: file,
                line: line)
        }
        XCTAssertEqual(animationKeys(list), [], "no CoreAnimation animation", file: file, line: line)
    }

    /// Samples the rows' containers and hosted views on every refresh.
    @available(macOS 14, *)
    private func record(
        _ rows: [Moving], in list: ExactListView, for seconds: TimeInterval
    ) async
        -> [PresentationSampler.Frame]
    {
        await PresentationSampler.record(
            rows.flatMap { [$0.view] + ($0.view.hostedView.map { [$0] } ?? []) }, in: list, for: seconds)
    }

    /// `record`, in two halves, checking between them what a sample can't
    /// see: no layer animates, and every row inside the viewport has a
    /// non-empty `visibleRect`, so AppKit draws it (M3).
    @available(macOS 14, *)
    private func recordChecking(
        _ rows: [Moving], in list: ExactListView, for seconds: TimeInterval, file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> [PresentationSampler.Frame] {
        let started = CACurrentMediaTime()
        var samples = await record(rows, in: list, for: seconds / 2)
        XCTAssertGreaterThan(clocks(in: list), 0, "mid-motion", file: file, line: line)
        XCTAssertEqual(animationKeys(list), [], "no CoreAnimation animation mid-motion", file: file, line: line)
        for row in rows where !row.view.isHidden {
            let frame = list.convert(row.view.bounds, from: row.view)
            guard frame.height > 0, frame.intersects(list.bounds) else { continue }
            XCTAssertFalse(
                row.view.visibleRect.isEmpty, "\(row.label): visible where it is shown", file: file, line: line)
        }
        let resumed = CACurrentMediaTime() - started
        samples += await record(rows, in: list, for: seconds / 2).map {
            PresentationSampler.Frame(elapsed: resumed + $0.elapsed, frames: $0.frames, opacities: $0.opacities)
        }
        return samples
    }

    /// SPEC §13's oracle. At each sample, `p` is read off the row that moves
    /// farthest, and every row must be where M2 puts it at that `p`, its
    /// hosted view filling it; `p` never decreases; and unless `ends` is
    /// false, the last sample is the end layout.
    @discardableResult
    private func progress(
        of rows: [Moving], in samples: [PresentationSampler.Frame], ends: Bool = true,
        file: StaticString = #filePath, line: UInt = #line
    ) -> [(sample: PresentationSampler.Frame, p: CGFloat)] {
        // A removed row is gone once it lands, so p is read off one that stays.
        guard let reference = rows.filter({ $0.end.height > 0 }).max(by: { $0.spread < $1.spread }),
            reference.spread > 0
        else {
            XCTFail("nothing moves", file: file, line: line)
            return []
        }
        var timeline: [(sample: PresentationSampler.Frame, p: CGFloat)] = []
        for sample in samples {
            guard let frame = sample.frames[ObjectIdentifier(reference.view)] else { continue }
            let p = reference.progress(of: frame)
            if let last = timeline.last?.p, p < last - 1e-6 {
                XCTFail("at \(sample.elapsed) s: p went back from \(last) to \(p)", file: file, line: line)
            }
            timeline.append((sample, p))
            for row in rows {
                guard let presented = sample.frames[ObjectIdentifier(row.view)] else { continue }
                let at = "\(row.label) at \(sample.elapsed) s, p \(p)"
                let expected = row.at(p)
                XCTAssertEqual(
                    presented.minY, expected.top, accuracy: Self.accuracy, "\(at): top", file: file, line: line)
                XCTAssertEqual(
                    presented.height, expected.height, accuracy: Self.accuracy, "\(at): height", file: file, line: line)
                guard row.contentStill, let hosted = row.view.hostedView,
                    let content = sample.frames[ObjectIdentifier(hosted)]
                else { continue }
                XCTAssertEqual(
                    content.minY, presented.minY, accuracy: Self.accuracy, "\(at): content at its top", file: file,
                    line: line)
                XCTAssertEqual(
                    content.height, presented.height, accuracy: Self.accuracy, "\(at): content fills it", file: file,
                    line: line)
            }
        }
        XCTAssertGreaterThan(timeline.count, 10, "sampled the motion", file: file, line: line)
        if ends {
            XCTAssertEqual(
                timeline.last?.p ?? 0, 1, accuracy: 1e-6, "the last sample is the end layout", file: file, line: line)
        }
        return timeline
    }

    /// The samples follow `p = f((elapsed − t₀) / T)`: fits the start `t₀`
    /// that best matches them, then requires every sample within 0.02 of the
    /// curve (linear and ease in–ease out differ by up to 0.12), and `p` to
    /// reach 1 within one frame of `T`.
    private func assertTimeline(
        _ timeline: [(sample: PresentationSampler.Frame, p: CGFloat)], duration: TimeInterval,
        curve: (CGFloat) -> CGFloat, _ label: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        func error(_ t0: TimeInterval) -> CGFloat {
            timeline.map { abs($0.p - curve(CGFloat(min(1, max(0, ($0.sample.elapsed - t0) / duration))))) }.max() ?? 0
        }
        let candidates = stride(from: -0.05, through: 0.1, by: 0.0005)
        let t0 = candidates.min { error($0) < error($1) } ?? 0
        let frame = 1 / Double(NSScreen.main?.maximumFramesPerSecond ?? 60)
        XCTAssertLessThan(error(t0), 0.02, "\(label): p follows the curve", file: file, line: line)
        if let ended = timeline.first(where: { $0.p >= 1 - 1e-6 })?.sample.elapsed {
            XCTAssertEqual(
                ended - t0, duration, accuracy: frame + 1e-3, "\(label): p reaches 1 at T", file: file, line: line)
        } else {
            XCTFail("\(label): p never reached 1", file: file, line: line)
        }
    }

    /// The first `y` in `[from, to]` that no rect covers, allowing gaps up to
    /// `tolerance` between them.
    private func firstHole(in rects: [CGRect], from: CGFloat, to: CGFloat, tolerance: CGFloat) -> CGFloat? {
        guard from < to else { return nil }
        var reach = from
        for rect in rects.sorted(by: { $0.minY < $1.minY }) {
            if rect.minY > reach + tolerance { break }
            reach = max(reach, rect.maxY)
            if reach >= to { return nil }
        }
        return reach >= to ? nil : reach
    }

    /// A timing curve's progress at time fraction `x`: the cubic Bézier from
    /// (0, 0) to (1, 1) with control points (x1, y1) and (x2, y2), solved by
    /// bisection. The points are the curve's own, as CoreAnimation defines it.
    private static func bezier(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) -> (CGFloat) -> CGFloat {
        func cubic(_ s: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
            3 * (1 - s) * (1 - s) * s * a + 3 * (1 - s) * s * s * b + s * s * s
        }
        return { x in
            var low: CGFloat = 0
            var high: CGFloat = 1
            for _ in 0..<60 {
                let mid = (low + high) / 2
                if cubic(mid, x1, x2) < x { low = mid } else { high = mid }
            }
            return cubic((low + high) / 2, y1, y2)
        }
    }
}
