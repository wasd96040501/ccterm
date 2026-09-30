import ApplicationServices
import ExactListTestSupport
import XCTest

@testable import ExactList

/// The accessibility table and rows, through the protocol: §11.
///
/// Each method proves the requirement in its name. `SpecCoverageTests` checks
/// that every ID in `SPEC.md` has one.
@MainActor
final class AccessibilityTests: XCTestCase {

    /// Found from the list the way the accessibility server walks it (unignored
    /// children), the table has `n` rows, mounted or not, each with its index;
    /// the visible rows are the ones that intersect `U`, from the test's model.
    func testX1_theTableElement() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        let host = LabelHost(heights: (0..<500).map { 18 + CGFloat(($0 * 11) % 41) + 0.5 })
        let list = ExactListView(dataSource: host, delegate: host)
        let insets = NSEdgeInsets(top: 20, left: 0, bottom: 30, right: 0)
        list.contentInsets = insets
        await stage.mount(list)
        let table = try tableElement(in: list)
        XCTAssertEqual(table.accessibilityRole(), .table)

        for row in [0, 120, 200, 499] {
            list.scrollToRow(row, at: .centeredVertically)
            await stage.settle()
            let rows = try XCTUnwrap(table.accessibilityRows())
            XCTAssertEqual(rows.count, host.heights.count)
            XCTAssertEqual(table.accessibilityRowCount(), host.heights.count)
            XCTAssertEqual(rows.map { index(of: $0) }, Array(0..<host.heights.count), "one element per row, in order")
            let visible = try XCTUnwrap(table.accessibilityVisibleRows()).map { index(of: $0) }
            XCTAssertEqual(visible, Array(expectedVisibleRows(list, host, insets)), "rows intersecting U near \(row)")
        }

        host.heights.insert(contentsOf: [40, 40], at: 3)
        list.insertRows(at: [3, 4])
        XCTAssertEqual(table.accessibilityRowCount(), 502)
        XCTAssertEqual(try XCTUnwrap(table.accessibilityRows()).count, 502)
    }

    /// Mounted and unmounted: role, index, parent, the frame on screen (mid
    /// motion, where the row is drawn), and the host view's unignored elements
    /// as children, which for a plain `NSView` host is its label.
    func testX2_rowElements() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        let host = LabelHost(heights: (0..<300).map { 20 + CGFloat(($0 * 7) % 23) })
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)
        list.scrollToRow(100, at: .top)
        await stage.settle()
        let table = try tableElement(in: list)
        let rows = try XCTUnwrap(table.accessibilityRows())

        for row in [100, 103, 5, 250] {
            let element = rows[row]
            let mounted = list.view(atRow: row) != nil
            XCTAssertEqual(role(of: element), .row, "row \(row)")
            XCTAssertEqual(index(of: element), row)
            XCTAssertTrue(parent(of: element) === table, "row \(row): its parent is the table")
            XCTAssertEqual(frame(of: element), expectedScreenFrame(list, host, row), "row \(row)")
            let children = (element as? NSAccessibilityProtocol)?.accessibilityChildren() ?? []
            if mounted {
                // The label's element (AppKit's: its cell), not the ignored NSView.
                XCTAssertEqual(children.count, 1, "row \(row): the host's one element: \(children)")
                let child = try XCTUnwrap(children.first as? NSAccessibilityProtocol)
                XCTAssertEqual(child.accessibilityRole(), .staticText, "row \(row)")
                XCTAssertEqual(child.accessibilityValue() as? String, "row \(row)")
            } else {
                XCTAssertTrue(children.isEmpty, "row \(row) isn't mounted: no children")
            }
        }

        // Mid-motion the frame is where the row is drawn: at the commit's
        // return, where it was (U1); once the motion ends, where it went.
        // Under Reduce Motion it is there at once (M1).
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        let before = expectedScreenFrame(list, host, 103)
        var done = false
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.3
                host.heights.insert(contentsOf: [60, 60], at: 101)
                list.performBatchUpdates({ $0.insertRows(at: [101, 102], withAnimation: .effectGap) }) { done = $0 }
            }, completionHandler: nil)
        let moving = try XCTUnwrap(table.accessibilityRows())[105]
        XCTAssertEqual(index(of: moving), 105)
        XCTAssertEqual(
            frame(of: moving), reduceMotion ? expectedScreenFrame(list, host, 105) : before,
            "where it is drawn: its motion's start")
        _ = await stage.drain(until: { done }, timeout: 2)
        XCTAssertTrue(done)
        XCTAssertEqual(frame(of: moving), expectedScreenFrame(list, host, 105), "where it went")
    }

    /// An unmounted row is a plain accessibility element, the same one each
    /// time it's asked for. Focusing it scrolls the least amount and mounts
    /// it. Its element is dropped when its row is removed, and on
    /// `reloadData()`.
    func testX3_unmountedRows() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        let host = LabelHost(heights: Array(repeating: 30, count: 400))
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)
        let table = try tableElement(in: list)

        let element = try XCTUnwrap(table.accessibilityRows())[60]
        XCTAssertFalse(element is NSView, "an NSAccessibilityElement, not a view")
        XCTAssertTrue(element is NSAccessibilityElement)
        XCTAssertNil(list.view(atRow: 60))
        XCTAssertTrue(try XCTUnwrap(table.accessibilityRows())[60] as AnyObject === element as AnyObject, "kept")

        (element as? NSAccessibilityElement)?.setAccessibilityFocused(true)
        await stage.settle()
        XCTAssertEqual(list.rect(ofRow: 60).maxY, 300, "the least scroll (S1): its bottom on U's")
        XCTAssertEqual(-list.rect(ofRow: 0).minY, 61 * 30 - 300)
        let mounted = try XCTUnwrap(list.view(atRow: 60), "focus mounted the row")
        let now = try XCTUnwrap(table.accessibilityRows())[60]
        XCTAssertTrue((now as? NSView)?.subviews.contains(mounted) ?? false, "the row's element is now its container")

        weak var removed: NSAccessibilityElement?
        weak var reloaded: NSAccessibilityElement?
        autoreleasepool {
            removed = table.accessibilityRows()?[300] as? NSAccessibilityElement
            reloaded = table.accessibilityRows()?[350] as? NSAccessibilityElement
        }
        XCTAssertNotNil(removed, "kept while its row exists")
        XCTAssertNotNil(reloaded)
        host.heights.remove(at: 300)
        list.removeRows(at: [300])
        XCTAssertNil(removed, "dropped with its row")
        XCTAssertNotNil(reloaded, "another row's element is kept")
        list.reloadData()
        XCTAssertNil(reloaded, "dropped on reloadData()")
    }

    /// Commits renumber the elements the reader holds: inserts and removals
    /// above, and a move, keep each element on its row, with its new index and
    /// frame; the table hands out that same element at the new index.
    func testX4_stableElements() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        let host = LabelHost(heights: (0..<400).map { 20 + CGFloat($0 % 9) * 2 })
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)
        list.scrollToRow(200, at: .top)
        await stage.settle()
        let table = try tableElement(in: list)
        let rows = try XCTUnwrap(table.accessibilityRows())
        var held: [(element: AnyObject, row: Int)] = [(rows[205] as AnyObject, 205), (rows[350] as AnyObject, 350)]
        XCTAssertTrue(held[0].element is NSView, "row 205 is mounted: its container")
        XCTAssertFalse(held[1].element is NSView, "row 350 isn't")

        func check(_ step: String) throws {
            let rows = try XCTUnwrap(table.accessibilityRows())
            XCTAssertEqual(rows.count, host.heights.count, step)
            for (element, row) in held {
                XCTAssertEqual(index(of: element), row, "\(step): index")
                XCTAssertTrue(
                    rows[row] as AnyObject === element, "\(step): the table hands out the same element at \(row)")
                XCTAssertEqual(frame(of: element), expectedScreenFrame(list, host, row), "\(step): frame of \(row)")
            }
        }

        host.heights.insert(contentsOf: [33, 34, 35], at: 10)
        list.insertRows(at: [10, 11, 12])
        held = held.map { ($0.element, $0.row + 3) }
        try check("insert above")

        host.heights.removeSubrange(0..<2)
        list.removeRows(at: [0, 1])
        held = held.map { ($0.element, $0.row - 2) }
        try check("remove above")

        let moved = host.heights.remove(at: 351)
        host.heights.insert(moved, at: 20)
        list.moveRow(at: 351, to: 20)
        held = [(held[0].element, held[0].row + 1), (held[1].element, 20)]
        try check("move")
    }

    /// Heard through an `AXObserver` on this process: a commit that changes
    /// `n` posts `AXRowCountChanged` on the table, whose `AXRows` then has the
    /// new count; commits that keep `n` post nothing.
    func testX5_notifications() async throws {
        try XCTSkipUnless(AXIsProcessTrusted(), "X5 needs this process trusted for accessibility (SPEC §13)")
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        let host = LabelHost(heights: Array(repeating: 30, count: 50))
        let list = ExactListView(dataSource: host, delegate: host)
        await stage.mount(list)
        let recorder = try await RowCountRecorder.start()
        defer { recorder.stop() }

        func heard(_ what: String) async -> [String] {
            _ = await stage.drain(until: { false }, timeout: 0.3)
            defer { recorder.heard.removeAll() }
            return recorder.heard
        }
        _ = await heard("mount")

        host.heights.append(contentsOf: [30, 30])
        list.insertRows(at: [50, 51])
        let afterInsert = await heard("insert")
        XCTAssertEqual(afterInsert, ["AXTable rows 52"], "an insert")

        host.heights[3] = 60
        list.noteHeightOfRows(withIndexesChanged: [3])
        list.reloadData(forRowIndexes: [4])
        host.heights.insert(host.heights.remove(at: 5), at: 9)
        list.moveRow(at: 5, to: 9)
        let afterSameCount = await heard("same count")
        XCTAssertEqual(afterSameCount, [], "n unchanged: nothing posted")

        host.heights.removeSubrange(10..<20)
        list.performBatchUpdates { $0.removeRows(at: IndexSet(integersIn: 10..<20)) }
        let afterRemove = await heard("remove")
        XCTAssertEqual(afterRemove, ["AXTable rows 42"], "a batch that removes")
    }

    // MARK: - Helpers

    /// The first unignored descendant of `list` with the table role, found the
    /// way the accessibility server walks the tree.
    private func tableElement(in list: ExactListView) throws -> NSAccessibilityProtocol {
        var queue: [Any] = NSAccessibility.unignoredChildren(from: [list])
        while !queue.isEmpty {
            let element = queue.removeFirst()
            guard let element = element as? NSAccessibilityProtocol else { continue }
            if element.accessibilityRole() == .table { return element }
            queue.append(contentsOf: element.accessibilityChildren() ?? [])
        }
        return try XCTUnwrap(nil, "no table element under the list")
    }

    private func role(of element: Any) -> NSAccessibility.Role? {
        (element as? NSAccessibilityProtocol)?.accessibilityRole()
    }

    private func index(of element: Any) -> Int {
        (element as? NSAccessibilityProtocol)?.accessibilityIndex() ?? -1
    }

    private func parent(of element: Any) -> AnyObject? {
        (element as? NSAccessibilityProtocol)?.accessibilityParent() as AnyObject?
    }

    private func frame(of element: Any) -> NSRect {
        (element as? NSAccessibilityProtocol)?.accessibilityFrame() ?? .null
    }

    /// `o`, from where row 0 is: the only thing read back from the list.
    private func offset(of list: ExactListView) -> CGFloat {
        -list.rect(ofRow: 0).minY
    }

    /// The row's frame from the model at the list's offset, on screen through
    /// AppKit's own conversions.
    private func expectedScreenFrame(_ list: ExactListView, _ host: LabelHost, _ row: Int) -> NSRect {
        let width = list.subviews.compactMap { $0 as? NSScrollView }.first?.contentView.bounds.width ?? 0
        var frame = ReferenceLayout.frames(heights: host.heights, spacing: 0, width: width)[row]
        frame.origin.y -= offset(of: list)
        return list.window?.convertToScreen(list.convert(frame, to: nil)) ?? .null
    }

    /// The rows whose model frames intersect `U`.
    private func expectedVisibleRows(_ list: ExactListView, _ host: LabelHost, _ insets: NSEdgeInsets) -> [Int] {
        let o = offset(of: list)
        let top = o + insets.top
        let bottom = o + list.bounds.height - insets.bottom
        let frames = ReferenceLayout.frames(heights: host.heights, spacing: 0, width: 1)
        return frames.indices.filter { frames[$0].maxY > top && frames[$0].minY < bottom }
    }

    /// Rows of the given heights, each a plain `NSView` holding a label that
    /// reads "row N": the host view is ignored, its label is the element.
    @MainActor
    private final class LabelHost: ExactListViewDataSource, ExactListViewDelegate {

        var heights: [CGFloat]

        init(heights: [CGFloat]) {
            self.heights = heights
        }

        func numberOfRows(in listView: ExactListView) -> Int {
            heights.count
        }

        func listView(_ listView: ExactListView, heightOfRow row: Int, width: CGFloat) -> CGFloat {
            heights[row]
        }

        func listView(_ listView: ExactListView, viewForRow row: Int) -> NSView {
            let view = listView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("label")) {
                let view = NSView()
                let label = NSTextField(labelWithString: "")
                label.frame = NSRect(x: 4, y: 2, width: 200, height: 16)
                view.addSubview(label)
                return view
            }
            label(in: view)?.stringValue = "row \(row)"
            return view
        }

        func label(in view: NSView) -> NSTextField? {
            view.subviews.first as? NSTextField
        }
    }

    /// `AXRowCountChanged` from this process, as a client hears it: an
    /// `AXObserver` on our own pid, registered off the main thread (the main
    /// thread answers the registration), delivered on the main run loop.
    @MainActor
    private final class RowCountRecorder {

        /// "<role> rows <AXRows count>" for each notification.
        var heard: [String] = []

        private let observer: AXObserver
        private let application: AXUIElement

        private init(observer: AXObserver, application: AXUIElement) {
            self.observer = observer
            self.application = application
        }

        static func start() async throws -> RowCountRecorder {
            // An app joins the accessibility runtime as it finishes launching,
            // which the xctest process never does; without it, registering fails
            // with kAXErrorNotImplemented (measured).
            NSApplication.shared.finishLaunching()
            var made: AXObserver?
            let callback: AXObserverCallback = { _, element, _, refcon in
                guard let refcon else { return }
                let recorder = Unmanaged<RowCountRecorder>.fromOpaque(refcon).takeUnretainedValue()
                var role: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
                var count: CFIndex = -1
                AXUIElementGetAttributeValueCount(element, kAXRowsAttribute as CFString, &count)
                MainActor.assumeIsolated { recorder.heard.append("\(role.map { "\($0)" } ?? "?") rows \(count)") }
            }
            let created = AXObserverCreate(getpid(), callback, &made)
            let observer = try XCTUnwrap(made, "AXObserverCreate: \(created.rawValue)")
            let recorder = RowCountRecorder(observer: observer, application: AXUIElementCreateApplication(getpid()))
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            let refcon = Unmanaged.passUnretained(recorder).toOpaque()
            let box = ObserverBox(observer: observer, application: recorder.application, refcon: refcon)
            let added = await withCheckedContinuation { continuation in
                Thread.detachNewThread {
                    continuation.resume(returning: box.add())
                }
            }
            XCTAssertEqual(added, .success, "AXObserverAddNotification")
            return recorder
        }

        func stop() {
            AXObserverRemoveNotification(observer, application, kAXRowCountChangedNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
    }

    /// What the registering thread needs; the AX types are thread-safe CF types.
    private struct ObserverBox: @unchecked Sendable {
        let observer: AXObserver
        let application: AXUIElement
        let refcon: UnsafeMutableRawPointer

        func add() -> AXError {
            AXObserverAddNotification(observer, application, kAXRowCountChangedNotification as CFString, refcon)
        }
    }
}
