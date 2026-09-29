import AppKit
import ExactListTestSupport
import XCTest

/// What `NSTableView` actually does, asserted on the OS the suite runs on. These
/// back every "Characterized" claim in `SPEC.md` §2. If one fails, AppKit
/// changed, and §2 has to change with it.
@MainActor
final class NSTableViewCharacterizationTests: XCTestCase {

    /// §2 Geometry: `reloadData()` over 10 000 rows asks for far fewer heights
    /// than there are rows, and the document height it reports before the reader
    /// scrolls differs from the sum of the heights.
    func testCharacterizesEstimatedGeometry() async throws {
        let stage = ListStage(size: NSSize(width: 480, height: 600))
        defer { stage.teardown() }
        let rows = 10_000
        let host = RecordingTableHost(count: rows) { row, _ in 20 + CGFloat(row % 7) * 30 }
        let table = host.makeTableView()
        _ = await stage.mountTable(table, layOutFirst: true)

        var asked = Set<Int>()
        for case .heightOfRow(let row, _) in host.calls { asked.insert(row) }
        let sum = (0..<rows).reduce(CGFloat(0)) { $0 + host.height($1, 0) }

        XCTAssertLessThan(asked.count, rows / 2, "NSTableView asked \(asked.count) of \(rows) heights")
        XCTAssertGreaterThan(
            abs(table.frame.height - sum), 1,
            "document height \(table.frame.height) equals the sum of the heights \(sum): nothing was estimated")
    }

    /// §2 Scroll position: with the viewport in the middle, inserting a row above
    /// it changes which row is at the top of the viewport.
    func testCharacterizesContentMovingOnInsertAbove() async throws {
        let stage = ListStage(size: NSSize(width: 480, height: 600))
        defer { stage.teardown() }
        let host = RecordingTableHost(count: 100) { _, _ in 40 }
        let table = host.makeTableView()
        let scroll = await stage.mountTable(table, layOutFirst: true)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: 50).minY))
        scroll.reflectScrolledClipView(scroll.contentView)
        await stage.settle()
        let before = table.row(at: NSPoint(x: 1, y: scroll.documentVisibleRect.minY + 1))

        host.count += 1
        table.insertRows(at: [0], withAnimation: [])
        await stage.settle()
        let after = table.row(at: NSPoint(x: 1, y: scroll.documentVisibleRect.minY + 1))

        XCTAssertEqual(before, 50)
        // The offset stayed where it was, so the index at the top is unchanged,
        // and that index now names the row that used to be one above.
        XCTAssertEqual(
            after, before,
            "the row that was at the top (now row \(before + 1)) is at row \(after): the content did not move")
    }

    /// M1 and P2: a height change's duration and curve, read off the animation
    /// `NSTableView` adds to the row below. Outside any group, 0.2 s
    /// `.easeOut`; in a group, the group's duration and curve, `nil` meaning
    /// `.default`, even when the group sets nothing. The current context is
    /// the same object inside a group and out, so that difference isn't
    /// public. The noted row's cell view is at its final size when the call
    /// returns.
    func testCharacterizesUpdateTiming() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        var heights: [CGFloat] = Array(repeating: 30, count: 40)
        let host = RecordingTableHost(count: heights.count) { row, _ in heights[row] }
        let table = host.makeTableView()
        _ = await stage.mountTable(table, layOutFirst: true)
        table.wantsLayer = true
        await stage.settle()

        /// Toggles row 5 between 30 and 90 in `group`, and returns the
        /// duration and control points of row 6's animation.
        func timing(_ group: (() -> Void) -> Void) async throws -> (TimeInterval, [Float]) {
            heights[5] = heights[5] == 30 ? 90 : 30
            group { table.noteHeightOfRows(withIndexesChanged: [5]) }
            let cell = try XCTUnwrap(table.view(atColumn: 0, row: 5, makeIfNecessary: false))
            XCTAssertEqual(cell.frame.height, heights[5], "the cell view is final at once")
            let layer = try XCTUnwrap(table.rowView(atRow: 6, makeIfNecessary: false)?.layer)
            let animation = try XCTUnwrap(
                layer.animationKeys()?.compactMap { layer.animation(forKey: $0) as? CABasicAnimation }.first)
            var points: [Float] = []
            for index in 1...2 {
                var values: [Float] = [0, 0]
                animation.timingFunction?.getControlPoint(at: index, values: &values)
                points += values
            }
            _ = await stage.drain(until: { false }, timeout: animation.duration + 0.1)
            return (animation.duration, points)
        }
        let easeOut: [Float] = [0, 0, 0.58, 1]
        let standard: [Float] = [0.25, 0.1, 0.25, 1]

        var (duration, points) = try await timing { $0() }
        XCTAssertEqual(duration, 0.2, "outside any group")
        XCTAssertEqual(points, easeOut)
        XCTAssertEqual(NSAnimationContext.current.duration, 0.25, "what the context reads there")
        XCTAssertNil(NSAnimationContext.current.timingFunction)

        (duration, points) = try await timing { body in
            NSAnimationContext.runAnimationGroup({ _ in body() }, completionHandler: nil)
        }
        XCTAssertEqual(duration, 0.25, "a group that sets nothing")
        XCTAssertEqual(points, standard)

        (duration, points) = try await timing { body in
            NSAnimationContext.runAnimationGroup(
                {
                    $0.duration = 0.4
                    body()
                }, completionHandler: nil)
        }
        XCTAssertEqual(duration, 0.4, "the group's duration")
        XCTAssertEqual(points, standard, "nil is .default")

        (duration, points) = try await timing { body in
            NSAnimationContext.runAnimationGroup(
                {
                    $0.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    body()
                }, completionHandler: nil)
        }
        XCTAssertEqual(points, [0.42, 0, 0.58, 1], "the group's curve")

        // What tells the two apart is AppKit's own state, which NSTableView
        // reads (traced) and the list reads too.
        let outside = ObjectIdentifier(NSAnimationContext.current)
        var inside: ObjectIdentifier?
        var activeInside: Bool?
        NSAnimationContext.runAnimationGroup(
            { _ in
                inside = ObjectIdentifier(NSAnimationContext.current)
                activeInside = Self.hasActiveGrouping()
            }, completionHandler: nil)
        XCTAssertEqual(inside, outside, "the same context object inside a group and out")
        XCTAssertEqual(Self.hasActiveGrouping(), false, "outside any group")
        XCTAssertEqual(activeInside, true, "in a group that sets nothing")
    }

    /// `+[NSAnimationContext _hasActiveGrouping]`, or `nil` if AppKit has no
    /// such method any more.
    private static func hasActiveGrouping() -> Bool? {
        let selector = NSSelectorFromString("_hasActiveGrouping")
        guard let method = class_getClassMethod(NSAnimationContext.self, selector) else { return nil }
        typealias Query = @convention(c) (AnyClass, Selector) -> Bool
        return unsafeBitCast(method_getImplementation(method), to: Query.self)(NSAnimationContext.self, selector)
    }

    /// §2 Setup order: a table given its data source and reloaded before layout
    /// asks for heights while its width is still 0.
    func testCharacterizesMeasuringBeforeLayout() async throws {
        let stage = ListStage(size: NSSize(width: 480, height: 600))
        defer { stage.teardown() }
        let host = RecordingTableHost(count: 50) { _, _ in 40 }
        let table = host.makeTableView()
        _ = await stage.mountTable(table, layOutFirst: false)

        let finalWidth = try XCTUnwrap(table.tableColumns.first?.width)
        var widths: [CGFloat] = []
        for case .heightOfRow(_, let width) in host.calls { widths.append(width) }

        XCTAssertGreaterThan(finalWidth, 100)
        XCTAssertTrue(
            widths.contains { abs($0 - finalWidth) > 1 },
            "every height was asked at the final width \(finalWidth): \(Set(widths))")
    }
}
