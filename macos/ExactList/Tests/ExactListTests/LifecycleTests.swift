import ExactListTestSupport
import XCTest

@testable import ExactList

/// Mount order, loading, and the calls before it: §4.
///
/// Each method proves the requirement in its name. `SpecCoverageTests` checks
/// that every ID in `SPEC.md` has one.
@MainActor
final class LifecycleTests: XCTestCase {

    /// The misuses L1 rules out don't compile against the built module, and a
    /// correct use beside them does, so the rejections are the API's.
    func testL1_injectedNotAssigned() async throws {
        try assertCompiles(
            """
            let list = ExactListView(dataSource: host, delegate: host)
            _ = list.dataSource
            _ = list.delegate
            """)
        try assertRejected([
            "let list = ExactListView(dataSource: host, delegate: host); list.dataSource = host",
            "let list = ExactListView(dataSource: host, delegate: host); list.delegate = host",
            "_ = ExactListView(frame: .zero)",
            "_ = ExactListView()",
        ])

        // Weak, as in AppKit: the list keeps neither alive.
        var host: RecordingHost? = RecordingHost(count: 3) { _, _ in 20 }
        let list = ExactListView(dataSource: host!, delegate: host!)
        XCTAssertTrue(list.dataSource === host)
        XCTAssertTrue(list.delegate === host)
        host = nil
        XCTAssertNil(list.dataSource)
        XCTAssertNil(list.delegate)
    }

    /// No part of the scroll view is reachable through the API, and in the view
    /// tree the list holds exactly one scroll view, whose document holds the
    /// host's views.
    func testL2_theListOwnsItsScrollView() async throws {
        try assertRejected([
            "let list = ExactListView(dataSource: host, delegate: host); _ = list.scrollView",
            "let list = ExactListView(dataSource: host, delegate: host); _ = list.clipView",
            "let list = ExactListView(dataSource: host, delegate: host); _ = list.documentView",
            "let list = ExactListView(dataSource: host, delegate: host); let _: NSScrollView = list",
        ])

        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        let host = RecordingHost(count: 50) { _, _ in 24 }
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)
        let scroll = try internalScrollView(of: list)
        XCTAssertEqual(list.subviews.count, 1)
        let document = try XCTUnwrap(scroll.documentView)
        let view = try XCTUnwrap(list.view(atRow: 0))
        XCTAssertTrue(view.isDescendant(of: document))
        XCTAssertTrue(view.enclosingScrollView === scroll)
    }

    /// Out of a window, and in one at width 0, the host hears nothing; it hears
    /// the first call once the width is positive.
    func testL3_nothingIsAskedBeforeTheLoadPoint() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        let host = RecordingHost(count: 50) { _, _ in 24 }
        let list = ExactListView(dataSource: host, delegate: host)
        list.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        list.layoutSubtreeIfNeeded()
        await stage.settle()
        XCTAssertEqual(host.calls, [], "out of a window")

        list.translatesAutoresizingMaskIntoConstraints = false
        stage.rootView.addSubview(list)
        let width = list.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            width, list.heightAnchor.constraint(equalToConstant: 300),
            list.topAnchor.constraint(equalTo: stage.rootView.topAnchor),
            list.leadingAnchor.constraint(equalTo: stage.rootView.leadingAnchor),
        ])
        await stage.settle()
        XCTAssertEqual(list.bounds.width, 0)
        XCTAssertEqual(host.calls, [], "in a window at width 0")

        width.constant = 400
        await stage.settle()
        XCTAssertEqual(host.calls.first, .numberOfRows, "loaded once the width is positive")
    }

    /// The first calls are exactly the count, every height in ascending order at
    /// `W`, then views for exactly the rows in `P`. Anything later is AppKit's
    /// own overdraw: the rows of the document's `preparedContentRect`, as
    /// AppKit itself reports it, within P1's bound.
    func testL4_loadingIsAutomatic() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        let heights: [CGFloat] = (0..<200).map { 20 + CGFloat(($0 * 13) % 30) }
        let host = RecordingHost(count: heights.count) { row, _ in heights[row] }
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)

        let width = try expectedWidth(of: list)
        let n = heights.count
        XCTAssertGreaterThan(host.calls.count, n + 1)
        XCTAssertEqual(host.calls[0], .numberOfRows)
        XCTAssertEqual(Array(host.calls[1...n]), (0..<n).map { .heightOfRow($0, width: width) })

        // At the top, with no insets: `P` is [−q, V + q], q = V / 2, and `U`'s
        // height is `V`.
        let frames = ReferenceLayout.frames(heights: heights, spacing: 0, width: width)
        let viewport = list.bounds.height
        func rows(from top: CGFloat, to bottom: CGFloat) -> Set<Int> {
            Set(frames.indices.filter { frames[$0].maxY > top && frames[$0].minY < bottom })
        }
        let inP = rows(from: -viewport / 2, to: viewport * 1.5)
        let atLoad = host.calls[(n + 1)..<(n + 1 + inP.count)]
        XCTAssertEqual(Set(atLoad.compactMap(viewRow)), inP, "the load asks for views for exactly the rows in P")

        let prepared = try XCTUnwrap(internalScrollView(of: list).documentView).preparedContentRect
        let overdraw = rows(
            from: max(prepared.minY, -viewport * 1.5), to: min(prepared.maxY, viewport * 2.5))
        let asked = host.calls[(n + 1)...].compactMap(viewRow)
        XCTAssertEqual(asked.count, host.calls.count - n - 1, "after the heights, only views are asked for")
        XCTAssertEqual(asked.count, Set(asked).count, "each row once")
        XCTAssertEqual(Set(asked), inP.union(overdraw), "P, and AppKit's prepared rect \(prepared), nothing else")
    }

    /// Before the load point: every update is ignored and the load reads the
    /// data source as it is then, a batch's completion still runs with `true`
    /// on a later turn, queries answer their defined values, and the last scroll
    /// request is applied at the load without animation.
    func testL5_callsBeforeTheLoadPointAreHarmlessAndDefined() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        let host = RecordingHost(count: 10) { _, _ in 30 }
        let list = ExactListView(dataSource: host, delegate: host)

        // Indexes that would be out of range, and a count that disagrees: all
        // ignored, so neither L10 nor L12 applies yet.
        list.insertRows(at: [0, 1, 2])
        list.removeRows(at: [40])
        list.moveRow(at: 3, to: 90)
        list.reloadData(forRowIndexes: [70])
        list.noteHeightOfRows(withIndexesChanged: [80])
        list.reloadData()
        var ranClosure = false
        var completions: [Bool] = []
        list.performBatchUpdates({ _ in ranClosure = true }, completionHandler: { completions.append($0) })
        XCTAssertEqual(completions, [], "never synchronously (U8)")

        XCTAssertEqual(list.numberOfRows, 0)
        XCTAssertEqual(list.rect(ofRow: 0), .zero)
        XCTAssertEqual(list.row(at: NSPoint(x: 5, y: 5)), -1)
        XCTAssertNil(list.view(atRow: 0))
        XCTAssertEqual(list.rows(in: NSRect(x: 0, y: 0, width: 400, height: 300)), 0..<0)
        XCTAssertFalse(list.isFollowingTail)

        list.scrollRowToVisible(5)
        list.scrollToRow(120, at: .top)
        host.count = 200
        XCTAssertEqual(host.calls, [])

        await stage.mount(list)
        XCTAssertFalse(ranClosure, "an ignored batch's updates never run")
        XCTAssertEqual(completions, [true])
        XCTAssertEqual(list.numberOfRows, 200, "the load reads the data source as it is then")
        XCTAssertEqual(host.calls.filter { $0 == .numberOfRows }.count, 1)
        XCTAssertEqual(list.rect(ofRow: 120).minY, 0, "the last scroll request wins")
        let view = try XCTUnwrap(list.view(atRow: 120))
        XCTAssertEqual(animationKeys(around: view), [], "applied without animation")
    }

    /// The recorded scroll request beats tail following, which beats the top.
    func testL6_theInitialPosition() async throws {
        let insets = NSEdgeInsets(top: 10, left: 0, bottom: 20, right: 0)
        func load(followsTail: Bool, request: Int?) async -> (ExactListView, ListStage, RecordingHost) {
            let stage = ListStage(size: NSSize(width: 400, height: 300))
            let host = RecordingHost(count: 100) { _, _ in 28 }
            let list = ExactListView(dataSource: host, delegate: host)
            list.contentInsets = insets
            list.automaticallyFollowsTail = followsTail
            if let request { list.scrollToRow(request, at: .top) }
            await stage.mount(list)
            return (list, stage, host)
        }

        let (requested, stage1, host1) = await load(followsTail: true, request: 40)
        defer { stage1.teardown() }
        XCTAssertEqual(requested.rect(ofRow: 40).minY, insets.top, "the request, over the tail")
        XCTAssertFalse(requested.isFollowingTail)
        _ = host1

        let (tail, stage2, host2) = await load(followsTail: true, request: nil)
        defer { stage2.teardown() }
        XCTAssertEqual(tail.rect(ofRow: 99).maxY, tail.bounds.height - insets.bottom, "the tail")
        XCTAssertTrue(tail.isFollowingTail)
        _ = host2

        let (top, stage3, host3) = await load(followsTail: false, request: nil)
        defer { stage3.teardown() }
        XCTAssertEqual(top.rect(ofRow: 0).minY, insets.top, "the top")
        _ = host3
    }

    /// Heights depend on the width. Every call gets the width the rows are shown
    /// at; collapsing the pane to 0 asks nothing and keeps the geometry; opening
    /// it again re-measures at the new width only.
    func testL7_neverMeasureAtAWidthThatWontBeShown() async throws {
        let stage = ListStage(size: NSSize(width: 600, height: 300))
        defer { stage.teardown() }
        let host = RecordingHost(count: 100) { row, width in 20 + CGFloat(row % 5) * 4 + 4000 / width }
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mountInSplit(list, leftWidth: 200)

        let loaded = try expectedWidth(of: list)
        XCTAssertEqual(Set(measuredWidths(host)), [loaded])
        XCTAssertEqual(list.rect(ofRow: 0).width, loaded)
        XCTAssertEqual(try XCTUnwrap(list.view(atRow: 0)).frame.width, loaded)
        let geometry = (0..<100).map { list.rect(ofRow: $0).height }

        host.resetCalls()
        await stage.moveDivider(to: 600, animated: false)
        XCTAssertEqual(list.bounds.width, 0, "the pane collapsed")
        XCTAssertEqual(host.calls, [], "nothing is asked at width 0")
        XCTAssertEqual(list.numberOfRows, 100)
        XCTAssertEqual((0..<100).map { list.rect(ofRow: $0).height }, geometry, "the geometry is kept")

        await stage.moveDivider(to: 300, animated: false)
        let reopened = try expectedWidth(of: list)
        XCTAssertNotEqual(reopened, loaded)
        XCTAssertEqual(Set(measuredWidths(host)), [reopened], "a width change, at the width shown")
        XCTAssertEqual(list.rect(ofRow: 0).height, host.height(0, reopened))
        XCTAssertEqual(try XCTUnwrap(list.view(atRow: 0)).frame.width, reopened)
    }

    /// Out of the window and back asks nothing and keeps heights, offset and the
    /// very same views; coming back at another width is a width change.
    func testL8_leavingTheWindowChangesNothing() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        let host = RecordingHost(count: 200) { row, width in 20 + CGFloat(row % 7) * 3 + 2000 / width }
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)
        list.scrollToRow(90, at: .top)
        await stage.settle()
        let rects = (0..<200).map { list.rect(ofRow: $0) }
        var views: [Int: NSView] = [:]
        list.enumerateAvailableRowViews { view, row in views[row] = view }
        XCTAssertFalse(views.isEmpty)

        host.resetCalls()
        stage.unmount(list)
        await stage.settle()
        await stage.mount(list)
        XCTAssertEqual(host.calls, [], "no call on the way out or back in")
        XCTAssertEqual((0..<200).map { list.rect(ofRow: $0) }, rects, "heights and offset kept")
        var after: [Int: NSView] = [:]
        list.enumerateAvailableRowViews { view, row in after[row] = view }
        XCTAssertEqual(Set(after.keys), Set(views.keys))
        for (row, view) in views { XCTAssertTrue(after[row] === view, "row \(row) kept its view") }

        stage.unmount(list)
        await stage.setContentSize(NSSize(width: 500, height: 300))
        XCTAssertEqual(host.calls, [], "resizing a window the list isn't in")
        await stage.mount(list)
        let width = try expectedWidth(of: list)
        XCTAssertFalse(host.calls.isEmpty)
        XCTAssertEqual(Set(measuredWidths(host)), [width], "back at another width: a width change")
    }

    /// Each violation traps in a child process with L9's ID; the one exception,
    /// a nested batch, flattens in this process.
    func testL9_reEntrancyIsAProgrammerError() async throws {
        for scenario in ["L9-callback", "L9-scroll", "L9-batch", "L9-query"] {
            try assertTraps(scenario, naming: "L9")
        }

        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        let host = RecordingHost(count: 20) { _, _ in 30 }
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)
        var completions: [Bool] = []
        host.count += 2
        list.performBatchUpdates(
            { updates in
                updates.insertRows(at: [0])
                list.performBatchUpdates(
                    { $0.insertRows(at: [0]) }, completionHandler: { completions.append($0) })
            }, completionHandler: { completions.append($0) })
        XCTAssertEqual(list.numberOfRows, 22, "the nested batch committed with the outer one")
        let drained = await stage.drain(until: { completions.count == 2 }, timeout: 2)
        XCTAssertTrue(drained)
        XCTAssertEqual(completions, [true, true])
    }

    func testL10_theCountIsChecked() async throws {
        try assertTraps("L10", naming: "L10")
    }

    /// The fixed configuration, read off the internal scroll view, and still in
    /// place after insets change and the window resizes.
    func testL11_theInternalScrollViewIsConfiguredOneWayAndItIsFixed() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        let host = RecordingHost(count: 100) { _, _ in 30 }
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)
        let scroll = try internalScrollView(of: list)

        func check(_ moment: String) {
            XCTAssertTrue(scroll.hasVerticalScroller, moment)
            XCTAssertFalse(scroll.hasHorizontalScroller, moment)
            XCTAssertFalse(scroll.drawsBackground, moment)
            XCTAssertFalse(scroll.contentView.drawsBackground, moment)
            XCTAssertFalse(scroll.automaticallyAdjustsContentInsets, moment)
            XCTAssertEqual(scroll.borderType, .noBorder, moment)
            XCTAssertEqual(scroll.scrollerStyle, NSScroller.preferredScrollerStyle, moment)
            XCTAssertEqual(scroll.verticalScrollElasticity, NSScrollView().verticalScrollElasticity, moment)
        }
        check("at load")

        let insets = NSEdgeInsets(top: 14, left: 0, bottom: 22, right: 0)
        list.contentInsets = insets
        await stage.setContentSize(NSSize(width: 520, height: 360))
        check("after insets and a resize")
        XCTAssertEqual(scroll.contentInsets.top, insets.top, "AppKit didn't rewrite the insets")
        XCTAssertEqual(scroll.contentInsets.bottom, insets.bottom)
    }

    func testL12_invalidInputIsAProgrammerError() async throws {
        let scenarios = [
            "L12-height", "L12-height-zero", "L12-spacing", "L12-spacing-inf", "L12-index", "L12-anchor",
            "L12-scroll", "L12-scroll-pending", "L12-dealloc", "L12-dealloc-load", "L12-dealloc-placement",
        ]
        for scenario in scenarios {
            try assertTraps(scenario, naming: "L12")
        }
    }

    // MARK: - Helpers

    /// The one scroll view in the list's own subtree (L2).
    private func internalScrollView(of list: ExactListView) throws -> NSScrollView {
        let scrolls = list.subviews.compactMap { $0 as? NSScrollView }
        XCTAssertEqual(scrolls.count, 1)
        return try XCTUnwrap(scrolls.first)
    }

    /// `W` as AppKit computes it for this frame and the system scroller style,
    /// independently of the list: what the rows must be shown at.
    private func expectedWidth(of list: ExactListView) throws -> CGFloat {
        let scroll = try internalScrollView(of: list)
        return NSScrollView.contentSize(
            forFrameSize: list.bounds.size, horizontalScrollerClass: nil, verticalScrollerClass: NSScroller.self,
            borderType: .noBorder, controlSize: .regular, scrollerStyle: scroll.scrollerStyle
        ).width
    }

    private func measuredWidths(_ host: RecordingHost) -> [CGFloat] {
        host.calls.compactMap {
            if case .heightOfRow(_, let width) = $0 { return width }
            return nil
        }
    }

    private func viewRow(_ call: HostCall) -> Int? {
        if case .viewForRow(let row) = call { return row }
        return nil
    }

    /// Animation keys on the view's layer and its container's.
    private func animationKeys(around view: NSView) -> [String] {
        [view.layer, view.superview?.layer].compactMap { $0?.animationKeys() }.flatMap { $0 }
    }

    /// Runs `ExactListProbe <scenario>` and asserts it trapped with `id` in the
    /// message.
    private func assertTraps(_ scenario: String, naming id: String, line: UInt = #line) throws {
        let outcome = try ProbeRunner.run(scenario)
        XCTAssertTrue(
            outcome.trapped, "\(scenario) ended with status \(outcome.status): \(outcome.standardError)", line: line)
        XCTAssertTrue(
            outcome.standardError.contains("(\(id))"), "\(scenario) trapped without \(id): \(outcome.standardError)",
            line: line)
    }

    // MARK: Compiling against the built module

    /// Type-checks `body` inside a function that has a `host` in scope, against
    /// the `ExactList` module this test bundle was built with.
    private func typecheck(_ bodies: [String]) throws -> (status: Int32, diagnostics: String) {
        let modules = try builtModules()
        let functions = bodies.enumerated().map { index, body in
            "@MainActor func use\(index)(_ host: ExactListViewDataSource & ExactListViewDelegate) {\n\(body)\n}"
        }
        let source = "import AppKit\nimport ExactList\n" + functions.joined(separator: "\n")
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExactListLifecycle-\(UUID().uuidString).swift")
        try source.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        #if arch(arm64)
        let target = "arm64-apple-macos12"
        #else
        let target = "x86_64-apple-macos12"
        #endif
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swiftc", "-typecheck", "-I", modules.path, "-target", target, file.path]
        let output = Pipe()
        process.standardError = output
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func assertCompiles(_ body: String, line: UInt = #line) throws {
        let result = try typecheck([body])
        XCTAssertEqual(result.status, 0, "the correct use must compile:\n\(result.diagnostics)", line: line)
    }

    /// Each body must fail on its own: they are checked one file each, so one
    /// error can't stand in for another.
    private func assertRejected(_ bodies: [String], line: UInt = #line) throws {
        for body in bodies {
            let result = try typecheck([body])
            XCTAssertNotEqual(result.status, 0, "compiled, but L1/L2 says it can't be written: \(body)", line: line)
            XCTAssertTrue(result.diagnostics.contains("error:"), "\(body): \(result.diagnostics)", line: line)
        }
    }

    /// The directory holding `ExactList.swiftmodule` beside this test bundle.
    private func builtModules() throws -> URL {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let candidates = [products, products.appendingPathComponent("Modules")]
        let found = candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("ExactList.swiftmodule").path)
        }
        return try XCTUnwrap(found, "ExactList.swiftmodule not found beside \(products.path)")
    }
}
