import ExactListTestSupport
import XCTest

@testable import ExactList

/// Motion frame by frame, from presentation layers: §8.
///
/// Each method proves the requirement in its name. `SpecCoverageTests` checks
/// that every ID in `SPEC.md` has one.
@MainActor
final class MotionTests: XCTestCase {

    /// Outside any group, an update animates for AppKit's 0.25 s with
    /// `.easeInEaseOut` (checked against the curve's own control points, at a
    /// scrubbed `T/4`); a group's duration and timing are what it uses; a
    /// duration-0 group, `reloadData()`, a width change and a scroll request
    /// without implicit animation add no animation anywhere, even inside a
    /// group that allows implicit animation. Reduce Motion: the branch this
    /// machine is in (§13).
    func testM1_whichCommitsAnimate() async throws {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        var heights: [CGFloat] = Array(repeating: 30, count: 200)
        let host = RecordingHost(count: heights.count) { row, _ in heights[row] }
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)
        list.scrollToRow(20, at: .top)
        await stage.settle()
        let document = try documentView(of: list)
        // Outside any group: 0.25 s, ease in–ease out, at a scrubbed T/4.
        let old = ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)
        let sampler = PresentationSampler(freezing: try XCTUnwrap(document.layer))
        heights.insert(45, at: 22)
        host.count = heights.count
        list.performBatchUpdates(anchoring: .scrollOffset) { $0.insertRows(at: [22]) }
        // Outside a group the commit reaches CoreAnimation with the implicit
        // transaction, so its animations begin at the next flush: flush at 0.
        sampler.scrub(to: 0)
        let new = ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)
        let mover = try container(ofRow: 25, in: list)
        if reduceMotion {
            XCTAssertEqual(allAnimationKeys(list), [], "Reduce Motion is on: nothing animates")
        } else {
            let animation = try XCTUnwrap(
                mover.layer?.animationKeys()?.compactMap { mover.layer?.animation(forKey: $0) as? CABasicAnimation }
                    .first { $0.keyPath == "position.y" })
            XCTAssertEqual(animation.duration, 0.25, "AppKit's duration outside any group")
            sampler.scrub(to: 0.25 / 4)
            let progress = Self.easeInEaseOut(0.25)
            let start = old[24].minY - 600
            let end = new[25].minY - 600
            XCTAssertEqual(
                sampler.presentedFrame(of: mover, in: list).minY, end + (start - end) * (1 - progress),
                accuracy: Self.presentedAccuracy, "ease in–ease out at T/4")
        }
        sampler.thaw()
        _ = await stage.drain(until: { self.allAnimationKeys(list).isEmpty }, timeout: 2)

        // A group's own duration and timing.
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.6
                context.timingFunction = CAMediaTimingFunction(name: .linear)
                heights[23] = 70
                list.noteHeightOfRows(withIndexesChanged: [23])
            }, completionHandler: nil)
        if !reduceMotion {
            let layer = try XCTUnwrap(container(ofRow: 24, in: list).layer)
            let animations = (layer.animationKeys() ?? []).compactMap {
                layer.animation(forKey: $0) as? CABasicAnimation
            }
            let position = try XCTUnwrap(animations.first { $0.keyPath == "position.y" })
            XCTAssertEqual(position.duration, 0.6, "the group's duration")
            XCTAssertEqual(position.timingFunction, CAMediaTimingFunction(name: .linear), "the group's timing")
        }
        _ = await stage.drain(until: { self.allAnimationKeys(list).isEmpty }, timeout: 2)

        // A duration-0 group turns animation off.
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0
                heights.remove(at: 21)
                host.count = heights.count
                list.removeRows(at: [21])
            }, completionHandler: nil)
        XCTAssertEqual(allAnimationKeys(list), [], "duration 0")

        // reloadData and a width change never animate, even with implicit
        // animation allowed; nor does a scroll request without it.
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.5
                context.allowsImplicitAnimation = true
                heights[22] = 90
                list.reloadData()
            }, completionHandler: nil)
        XCTAssertEqual(allAnimationKeys(list), [], "reloadData()")
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.5
                context.allowsImplicitAnimation = true
                stage.window.setContentSize(NSSize(width: 330, height: 300))
                stage.window.layoutIfNeeded()
            }, completionHandler: nil)
        XCTAssertEqual(list.rect(ofRow: 22).width, try documentView(of: list).bounds.width)
        XCTAssertEqual(allAnimationKeys(list), [], "a width change")
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.5
                list.scrollToRow(120, at: .top)
            }, completionHandler: nil)
        XCTAssertEqual(allAnimationKeys(list), [], "a scroll request without implicit animation")
    }

    /// With linear timing and every `t` scrubbed: the model is final at once;
    /// each container carries only additive `position.y` and
    /// `bounds.size.height` animations to 0, sharing `T` and `f`; and the
    /// presented top and height of every row equal M2's formula from the
    /// test's own model. First a height change alone, then a batch with an
    /// insert, a removal and a noted row. The host view sits at the
    /// container's top at its final height, with no animation of its own.
    func testM3_howItIsDone() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        var heights: [CGFloat] = Array(repeating: 30, count: 40)
        let host = RecordingHost(count: heights.count) { row, _ in heights[row] }
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)
        let document = try documentView(of: list)

        // A height change alone: row 5 from 30 to 60, row 0 held at the top.
        var old = ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)
        var sampler = PresentationSampler(freezing: try XCTUnwrap(document.layer))
        var finished = false
        heights[5] = 60
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 1
                context.timingFunction = CAMediaTimingFunction(name: .linear)
                list.performBatchUpdates({ $0.noteHeightOfRows(withIndexesChanged: [5]) }) { finished = $0 }
            }, completionHandler: nil)
        var new = ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)
        XCTAssertEqual(list.rect(ofRow: 0).minY, 0, "o is still 0")
        var expected: [(view: NSView, start: CGRect, end: CGRect, label: String)] = []
        for row in 0..<10 {
            expected.append((try container(ofRow: row, in: list), old[row], new[row], "row \(row)"))
        }
        try assertModelAndAnimations(expected, list: list, duration: 1)
        for t in [0, 0.25, 0.5, 0.75, 1] {
            sampler.scrub(to: t)
            assertPresented(expected, sampler: sampler, list: list, t: t)
        }
        sampler.thaw()
        _ = await stage.drain(until: { finished }, timeout: 3)
        XCTAssertTrue(finished)

        // Insert at 8 (40 tall), remove old 12, note row 3 (to 45), in one batch.
        old = ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)
        let removedContainer = try container(ofRow: 12, in: list)
        let removedHost = try XCTUnwrap(list.view(atRow: 12))
        sampler = PresentationSampler(freezing: try XCTUnwrap(document.layer))
        finished = false
        heights.remove(at: 12)
        heights.insert(40, at: 8)
        heights[3] = 45
        host.count = heights.count
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 1
                context.timingFunction = CAMediaTimingFunction(name: .linear)
                list.performBatchUpdates(
                    {
                        $0.removeRows(at: [12])
                        $0.insertRows(at: [8])
                        $0.noteHeightOfRows(withIndexesChanged: [3])
                    }, completionHandler: { finished = $0 })
            }, completionHandler: nil)
        new = ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)
        XCTAssertEqual(list.rect(ofRow: 0).minY, 0, "o is still 0")
        expected = []
        for newRow in 0..<11 where newRow != 8 {
            let oldRow = newRow < 8 ? newRow : newRow - 1
            expected.append((try container(ofRow: newRow, in: list), old[oldRow], new[newRow], "survivor \(oldRow)"))
        }
        // Inserted: its gap (after old 7) has no removed row: rule 2.
        expected.append(
            (
                try container(ofRow: 8, in: list), CGRect(x: 0, y: old[7].maxY, width: 1, height: 0), new[8],
                "inserted"
            ))
        // Removed: its gap (after old 11, now 12) has no inserted row: rule 2.
        expected.append(
            (removedContainer, old[12], CGRect(x: 0, y: new[12].maxY, width: 1, height: 0), "removed"))
        try assertModelAndAnimations(expected, list: list, duration: 1)
        XCTAssertEqual(list.row(for: removedHost), -1, "animating out")
        for t in [0, 0.2, 0.5, 0.8, 1] {
            sampler.scrub(to: t)
            assertPresented(expected, sampler: sampler, list: list, t: t)
            let removedTop = sampler.presentedFrame(of: removedContainer, in: list).minY
            let hosted = sampler.presentedFrame(of: removedHost, in: list)
            XCTAssertEqual(
                hosted.minY, removedTop, accuracy: Self.presentedAccuracy,
                "t \(t): the removed row's content at its top")
            XCTAssertEqual(hosted.height, 30, accuracy: Self.presentedAccuracy, "t \(t): at its own height, covered up")
        }
        sampler.thaw()
        _ = await stage.drain(until: { finished }, timeout: 3)
        XCTAssertTrue(finished)
    }

    /// From the display link, frame by frame as shown: every point of `U`
    /// between the content's presented edges is in a presented row or in a
    /// gap of at most `s`. A removal mid-viewport, a tall insert, a removal
    /// at the tail (clamped, A7), a removal and insert sharing a gap with
    /// spacing, and a long animated scroll (M7).
    func testM6_noBlankAreas() async throws {
        guard #available(macOS 14, *) else { throw XCTSkip("the display link needs macOS 14") }
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
            NSAnimationContext.runAnimationGroup(
                { context in
                    context.duration = 0.4
                    context.allowsImplicitAnimation = scenario == .longScroll
                    switch scenario {
                    case .midRemoval:
                        heights.removeSubrange(first + 3..<first + 6)
                        host.count = heights.count
                        list.performBatchUpdates({ $0.removeRows(at: IndexSet(first + 3..<first + 6)) }) {
                            finished = $0
                        }
                    case .tallInsert:
                        heights.insert(250, at: first + 2)
                        host.count = heights.count
                        list.performBatchUpdates({ $0.insertRows(at: [first + 2]) }) { finished = $0 }
                    case .tailRemoval:
                        heights.removeLast(5)
                        host.count = heights.count
                        list.performBatchUpdates({
                            $0.removeRows(at: IndexSet(heights.count..<heights.count + 5))
                        }) { finished = $0 }
                    case .sharedGapWithSpacing:
                        heights.remove(at: first + 4)
                        heights.insert(contentsOf: [70, 20], at: first + 4)
                        host.count = heights.count
                        list.performBatchUpdates({
                            $0.removeRows(at: [first + 4])
                            $0.insertRows(at: [first + 4, first + 5])
                        }) { finished = $0 }
                    case .longScroll:
                        list.scrollToRow(1500, at: .top)
                        finished = true
                    }
                }, completionHandler: nil)

            let document = try documentView(of: list)
            // Hidden containers are spares in no row (P3): they show nothing.
            let containers = document.subviews.compactMap { $0 as? RowContainerView }.filter { !$0.isHidden }
            let rowsAtCommit = Set(containers.map(\.row))
            let edgeTop = rowsAtCommit.contains(0)
            let edgeBottom = rowsAtCommit.contains(heights.count - 1)
            let frames = await PresentationSampler.record(containers, in: list, for: 0.38)
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

    /// A second commit at `t = 0.5` of a first one, both linear and scrubbed:
    /// presented frames don't move at that moment (C0), the first commit's
    /// animations are all still there, the second's anchor carries no motion
    /// of its own, and every row is the sum of both interpolations until both
    /// land on the model.
    func testM8_interruptionsCompose() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        var heights: [CGFloat] = Array(repeating: 30, count: 60)
        let host = RecordingHost(count: heights.count) { row, _ in heights[row] }
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)
        list.scrollToRow(10, at: .top)
        await stage.settle()
        let document = try documentView(of: list)
        let sampler = PresentationSampler(freezing: try XCTUnwrap(document.layer))
        let linear = CAMediaTimingFunction(name: .linear)

        // A: two rows above the viewport, the offset held: rows slide down 100.
        let f0 = ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)
        var firstDone: Bool?
        heights.insert(contentsOf: [50, 50], at: 3)
        host.count = heights.count
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 1
                context.timingFunction = linear
                list.performBatchUpdates(anchoring: .scrollOffset, { $0.insertRows(at: [3, 4]) }) { firstDone = $0 }
            }, completionHandler: nil)
        let f1 = ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)
        sampler.scrub(to: 0)
        sampler.scrub(to: 0.5)
        let watched = try (12..<20).map { try container(ofRow: $0, in: list) }
        let before = watched.map { sampler.presentedFrame(of: $0, in: list) }
        let keysBefore = watched.map { Set($0.layer?.animationKeys() ?? []) }

        // B at t = 0.5: one row above row 14, which is held.
        var secondDone: Bool?
        heights.insert(40, at: 13)
        host.count = heights.count
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 1
                context.timingFunction = linear
                list.performBatchUpdates(anchoring: .row(14), { $0.insertRows(at: [13]) }) { secondDone = $0 }
            }, completionHandler: nil)
        let f2 = ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)
        XCTAssertEqual(-list.rect(ofRow: 0).minY, 340, "B's offset: the anchor held")
        sampler.scrub(to: 0.5)
        for (index, view) in watched.enumerated() {
            let now = sampler.presentedFrame(of: view, in: list)
            XCTAssertEqual(now.minY, before[index].minY, accuracy: Self.presentedAccuracy, "row \(12 + index): C0 at B")
            XCTAssertEqual(now.height, before[index].height, accuracy: Self.presentedAccuracy)
            XCTAssertTrue(
                keysBefore[index].isSubset(of: Set(view.layer?.animationKeys() ?? [])),
                "row \(12 + index): A's animations are all still there")
        }

        // Row 14 after A (old 12) is B's anchor; row 12 after A (old 10) moves
        // in both. Presented = B's end + A's remaining + B's remaining.
        let anchor = watched[2]
        let both = watched[0]
        for t in [0.5, 0.75, 1, 1.25, 1.5] {
            sampler.scrub(to: t)
            let a = max(0, 1 - t)
            let b = min(1, max(0, 1.5 - t))
            let anchorTop = (f2[15].minY - 340) + ((f0[12].minY - 300) - (f1[14].minY - 300)) * a
            XCTAssertEqual(
                sampler.presentedFrame(of: anchor, in: list).minY, anchorTop, accuracy: Self.presentedAccuracy,
                "t \(t): B's anchor moves only by A")
            let bothTop =
                (f2[12].minY - 340) + ((f0[10].minY - 300) - (f1[12].minY - 300)) * a
                + ((f1[12].minY - 300) - (f2[12].minY - 340)) * b
            XCTAssertEqual(
                sampler.presentedFrame(of: both, in: list).minY, bothTop, accuracy: Self.presentedAccuracy,
                "t \(t): A and B add up")
        }
        sampler.thaw()
        _ = await stage.drain(until: { firstDone != nil && secondDone != nil }, timeout: 3)
        XCTAssertEqual(firstDone, true)
        XCTAssertEqual(secondDone, true)
    }

    /// Each effect, inserted and removed, scrubbed with linear timing: the
    /// container's presented opacity for a fade, and the host view's offset
    /// inside its container for a slide, in screen coordinates.
    func testM9_effects() async throws {
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
            let document = try documentView(of: list)
            let width = document.bounds.width

            for inserting in [true, false] {
                let phase = "\(name) \(inserting ? "insert" : "remove")"
                let sampler = PresentationSampler(freezing: try XCTUnwrap(document.layer))
                var done = false
                let row: NSView
                NSAnimationContext.runAnimationGroup(
                    { context in
                        context.duration = 1
                        context.timingFunction = CAMediaTimingFunction(name: .linear)
                        if inserting {
                            heights.insert(50, at: 3)
                            host.count = heights.count
                            list.performBatchUpdates({ $0.insertRows(at: [3], withAnimation: option) }) { done = $0 }
                        } else {
                            heights.remove(at: 3)
                            host.count = heights.count
                            list.performBatchUpdates({ $0.removeRows(at: [3], withAnimation: option) }) { done = $0 }
                        }
                    }, completionHandler: nil)
                if inserting {
                    row = try container(ofRow: 3, in: list)
                } else {
                    row = try XCTUnwrap(
                        document.subviews.compactMap { $0 as? RowContainerView }.first { !$0.isHidden && $0.row == -1 },
                        phase)
                }
                let hosted = try XCTUnwrap((row as? RowContainerView)?.hostedView)
                for t in [0, 0.25, 0.5, 0.75, 1] {
                    sampler.scrub(to: t)
                    let clip = sampler.presentedFrame(of: row, in: list)
                    let content = sampler.presentedFrame(of: hosted, in: list)
                    let dx = content.minX - clip.minX
                    let dy = content.minY - clip.minY
                    let p = CGFloat(t)
                    let shown: CGFloat = inserting ? p : 1 - p
                    let away: CGFloat = inserting ? 1 - p : p
                    let sign: CGFloat = inserting ? 1 : -1
                    var expectedX: CGFloat = 0
                    var expectedY: CGFloat = 0
                    if option == .slideUp { expectedY = sign * 50 * away }
                    if option == .slideDown { expectedY = -sign * 50 * away }
                    if option == .slideLeft { expectedX = sign * width * away }
                    if option == .slideRight { expectedX = -sign * width * away }
                    XCTAssertEqual(
                        dx, expectedX, accuracy: Self.presentedAccuracy, "\(phase) t \(t): horizontal offset")
                    XCTAssertEqual(dy, expectedY, accuracy: Self.presentedAccuracy, "\(phase) t \(t): vertical offset")
                    let opacity = sampler.presentedOpacity(of: row)
                    let expectedOpacity: Float = option.contains(.effectFade) ? Float(shown) : 1
                    XCTAssertEqual(opacity, expectedOpacity, accuracy: 1e-4, "\(phase) t \(t): opacity")
                }
                sampler.thaw()
                _ = await stage.drain(until: { done }, timeout: 3)
                XCTAssertTrue(done, phase)
            }
        }
    }

    /// A move and a removal in one batch, scrubbed: the moved container is
    /// drawn above every other and travels straight; the removed one is drawn
    /// below every other, closes its slot, and stays mounted until its
    /// animation ends, when its host hears `didRemove` with row −1.
    func testM10_stackingOrder() async throws {
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
        let sampler = PresentationSampler(freezing: try XCTUnwrap(document.layer))
        var done = false
        let moved = heights.remove(at: 2)
        heights.insert(moved, at: 6)
        heights.remove(at: 9)
        host.count = heights.count
        host.resetCalls()
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 1
                context.timingFunction = CAMediaTimingFunction(name: .linear)
                list.performBatchUpdates(
                    {
                        $0.moveRow(at: 2, to: 6)
                        $0.removeRows(at: [9])
                    }, completionHandler: { done = $0 })
            }, completionHandler: nil)
        let new = ReferenceLayout.frames(heights: heights, spacing: 0, width: 1)
        let newIndex = [0: 0, 1: 1, 3: 2, 4: 3, 5: 4, 6: 5, 7: 7, 8: 8, 10: 9]

        let stack = document.subviews.compactMap { $0 as? RowContainerView }.filter { !$0.isHidden }
        XCTAssertTrue(stack.last === movedContainer, "the moved row is drawn above the others")
        XCTAssertTrue(stack.first === removedContainer, "the removed row is drawn below the others")

        var expected: [(view: NSView, start: CGRect, end: CGRect, label: String)] = [
            (movedContainer, old[2], new[6], "moved"),
            (removedContainer, old[9], CGRect(x: 0, y: new[8].maxY, width: 1, height: 0), "removed"),
        ]
        for (oldRow, view) in survivorsBefore {
            expected.append((view, old[oldRow], new[newIndex[oldRow]!], "survivor \(oldRow)"))
        }
        for t in [0, 0.3, 0.5, 0.9, 1] {
            sampler.scrub(to: t)
            assertPresented(expected, sampler: sampler, list: list, t: t)
        }
        XCTAssertNotNil(removedView.window, "still mounted while it animates")
        XCTAssertEqual(list.row(for: removedView), -1)
        XCTAssertFalse(host.calls.contains(.didRemove(ObjectIdentifier(removedView), row: -1)), "not yet removed")

        sampler.thaw()
        _ = await stage.drain(until: { done }, timeout: 3)
        XCTAssertTrue(done)
        XCTAssertTrue(
            host.calls.contains(.didRemove(ObjectIdentifier(removedView), row: -1)), "didRemove with −1 once it ends")
    }

    // MARK: - Helpers

    /// CoreAnimation evaluates presented values in single precision: a
    /// hundredth of a point, far below a pixel, and far above what it drifts.
    private static let presentedAccuracy: CGFloat = 0.01

    private enum BlankScenario: CaseIterable {
        case midRemoval, tallInsert, tailRemoval, sharedGapWithSpacing, longScroll
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

    /// Every animation key on every container and hosted view in the document.
    private func allAnimationKeys(_ list: ExactListView) -> [String] {
        guard let document = try? documentView(of: list) else { return [] }
        var keys: [String] = []
        for case let container as RowContainerView in document.subviews {
            keys += (container.layer?.animationKeys() ?? []).map { "row \(container.row) container \($0)" }
            keys += (container.hostedView?.layer?.animationKeys() ?? []).map { "row \(container.row) host \($0)" }
        }
        return keys
    }

    /// The model is final: each container's frame is its end (document
    /// frames `start`/`end` at offset `o`), and it carries only additive
    /// `position.y` and `bounds.size.height` animations from `start − end` to
    /// 0, with `duration` and linear timing. Hosted views carry none (P5).
    private func assertModelAndAnimations(
        _ rows: [(view: NSView, start: CGRect, end: CGRect, label: String)], list: ExactListView,
        duration: TimeInterval
    ) throws {
        let o = offset(of: list)
        for (view, start, end, label) in rows {
            let model = list.convert(view.bounds, from: view)
            XCTAssertEqual(model.minY, end.minY - o, accuracy: 1e-9, "\(label): model top final")
            XCTAssertEqual(model.height, end.height, accuracy: 1e-9, "\(label): model height final")
            let layer = try XCTUnwrap(view.layer)
            var deltas: [String: CGFloat] = [:]
            for key in layer.animationKeys() ?? [] {
                let animation = try XCTUnwrap(layer.animation(forKey: key) as? CABasicAnimation, "\(label): \(key)")
                let path = try XCTUnwrap(animation.keyPath)
                XCTAssertTrue(["position.y", "bounds.size.height"].contains(path), "\(label): only M3's, not \(path)")
                XCTAssertTrue(animation.isAdditive, "\(label): \(path) additive")
                XCTAssertEqual(animation.toValue as? CGFloat, 0, "\(label): \(path) to 0")
                XCTAssertEqual(animation.duration, duration, "\(label): \(path) shares T")
                XCTAssertEqual(animation.timingFunction, CAMediaTimingFunction(name: .linear), "\(label): shares f")
                deltas[path] = animation.fromValue as? CGFloat
            }
            let screenDelta = start.minY - end.minY
            XCTAssertEqual(deltas["position.y"] ?? 0, screenDelta, accuracy: 1e-9, "\(label): position from old − new")
            XCTAssertEqual(
                deltas["bounds.size.height"] ?? 0, start.height - end.height, accuracy: 1e-9,
                "\(label): height from old − new")
            if let hosted = (view as? RowContainerView)?.hostedView {
                XCTAssertEqual(hosted.layer?.animationKeys() ?? [], [], "\(label): the host view never animates")
            }
        }
    }

    /// M2 at `t` of a linear, 1 s commit that held the offset: presented top
    /// and height are `end + (start − end)·(1 − t)` in screen coordinates.
    /// Each row's hosted view sits at the container's presented top, at the
    /// row's final height.
    private func assertPresented(
        _ rows: [(view: NSView, start: CGRect, end: CGRect, label: String)], sampler: PresentationSampler,
        list: ExactListView, t: Double
    ) {
        let o = offset(of: list)
        let remaining = CGFloat(1 - t)
        for (view, start, end, label) in rows {
            let presented = sampler.presentedFrame(of: view, in: list)
            let top = (end.minY - o) + (start.minY - end.minY) * remaining
            let height = end.height + (start.height - end.height) * remaining
            XCTAssertEqual(presented.minY, top, accuracy: Self.presentedAccuracy, "\(label) t \(t): presented top")
            XCTAssertEqual(
                presented.height, height, accuracy: Self.presentedAccuracy, "\(label) t \(t): presented height")
            if let container = view as? RowContainerView, container.row >= 0, let hosted = container.hostedView {
                let content = sampler.presentedFrame(of: hosted, in: list)
                XCTAssertEqual(
                    content.minY, presented.minY, accuracy: Self.presentedAccuracy,
                    "\(label) t \(t): content at the top")
                XCTAssertEqual(
                    content.height, end.height, accuracy: Self.presentedAccuracy,
                    "\(label) t \(t): content at final height")
            }
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

    /// `.easeInEaseOut`'s progress at time fraction `x`: the cubic Bézier
    /// with control points (0.42, 0) and (0.58, 1), solved by bisection.
    private static func easeInEaseOut(_ x: CGFloat) -> CGFloat {
        func bezier(_ s: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
            3 * (1 - s) * (1 - s) * s * a + 3 * (1 - s) * s * s * b + s * s * s
        }
        var low: CGFloat = 0
        var high: CGFloat = 1
        for _ in 0..<60 {
            let mid = (low + high) / 2
            if bezier(mid, 0.42, 0.58) < x { low = mid } else { high = mid }
        }
        return bezier((low + high) / 2, 0, 1)
    }
}
