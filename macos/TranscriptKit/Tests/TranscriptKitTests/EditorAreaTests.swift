import AppKit
import XCTest

@testable import TranscriptWorkspace

/// The editor area mounted in a `TestWindow`: real split view, real tab
/// controllers, real tab bars, with probe view controllers in the tabs.
///
/// Driven through what AppKit itself calls — `mouseDown` on the tab bar, the
/// dragging-destination methods, a divider drag run through `NSSplitView`'s own
/// tracking loop — and asserted on what the tree then is.
@MainActor
final class EditorAreaTests: XCTestCase {

    private static let size = NSSize(width: 1000, height: 500)

    // MARK: - Tabs

    func testANewTabIsSelectedAndReportedActive() throws {
        let mounted = mount(tabs: 3)
        defer { mounted.window.close() }
        let group = mounted.area.activeGroup

        XCTAssertEqual(group.tabViewItems.count, 3, "premise: the tabs went in")
        XCTAssertEqual(group.selectedTabViewItemIndex, 2)
        XCTAssertIdentical(mounted.area.activeViewController, mounted.probes[2])
        XCTAssertIdentical(
            mounted.recorder.activated.last ?? nil, mounted.probes[2],
            "the delegate was not told which tab became active")
        XCTAssertEqual(group.tabBar.segmentCount, 3, "the bar does not show every tab")
        XCTAssertEqual(group.tabBar.selectedSegment, 2)
        XCTAssertEqual(group.tabBar.label(forSegment: 1), "Tab 1")
    }

    /// The performance claim, and the isolation one: one tab's view in the
    /// window at a time, whatever the number of tabs.
    func testOnlyTheSelectedTabsViewIsInTheWindow() throws {
        let mounted = mount(tabs: 4)
        defer { mounted.window.close() }

        mounted.area.activeGroup.selectedTabViewItemIndex = 1
        settle(mounted.window)

        let inWindow = mounted.probes.map { $0.isViewLoaded && $0.view.window != nil }
        XCTAssertEqual(inWindow, [false, true, false, false])
        XCTAssertIdentical(mounted.recorder.activated.last ?? nil, mounted.probes[1])
    }

    func testPressingATabSelectsIt() throws {
        let mounted = mount(tabs: 3)
        defer { mounted.window.close() }
        let bar = mounted.area.activeGroup.tabBar

        bar.mouseDown(with: mouse(.leftMouseDown, at: center(of: bar, tab: 0), in: bar))
        bar.mouseUp(with: mouse(.leftMouseUp, at: center(of: bar, tab: 0), in: bar))

        XCTAssertEqual(mounted.area.activeGroup.selectedTabViewItemIndex, 0)
        XCTAssertEqual(bar.selectedSegment, 0)
        XCTAssertIdentical(mounted.area.activeViewController, mounted.probes[0])
    }

    /// The selection slides to a pressed tab, as the control's own press slides
    /// it — the bar takes the mouse over, so it has to ask for that. Setting
    /// `selectedSegment` plainly lands it in one frame; measured against the
    /// control's accessibility press, which moves through two dozen.
    func testPressingATabSlidesTheSelectionThere() throws {
        guard #available(macOS 27.0, *) else { throw XCTSkip("the tab role is macOS 27's") }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            throw XCTSkip("Reduce Motion is on: the selection moves without sliding, by design")
        }
        let mounted = mount(tabs: 3)
        defer { mounted.window.close() }
        let bar = mounted.area.activeGroup.tabBar
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))

        bar.mouseDown(with: mouse(.leftMouseDown, at: center(of: bar, tab: 0), in: bar))
        bar.mouseUp(with: mouse(.leftMouseUp, at: center(of: bar, tab: 0), in: bar))
        var states: [[NSRect]] = []
        for _ in 0..<30 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0 / 60))
            let geometry = layerFrames(of: try XCTUnwrap(bar.layer))
            if states.last != geometry { states.append(geometry) }
        }

        XCTAssertEqual(bar.selectedSegment, 0, "premise: the press selected the tab")
        XCTAssertGreaterThan(states.count, 5, "the selection jumped instead of sliding")
    }

    func testTheTabsFillTheBarWithoutGapsOrOverlaps() throws {
        let mounted = mount(tabs: 3)
        defer { mounted.window.close() }
        let bar = mounted.area.activeGroup.tabBar
        mounted.area.activeGroup.setTabPinned(true, at: 1)
        settle(mounted.window)

        let rects = (0..<3).map { bar.rect(forTabAt: $0) }
        XCTAssertGreaterThan(bar.bounds.width, 300, "premise: the bar was laid out")
        XCTAssertEqual(rects[0].maxX, rects[1].minX, accuracy: 0.5)
        XCTAssertEqual(rects[1].maxX, rects[2].minX, accuracy: 0.5)
        XCTAssertEqual(rects[2].maxX, bar.bounds.maxX - 2, accuracy: 0.5)
        XCTAssertLessThan(
            rects[0].width, rects[1].width, "a pinned tab should be narrower than the rest")
    }

    func testRenamingATabRedrawsTheBar() throws {
        let mounted = mount(tabs: 2)
        defer { mounted.window.close() }

        mounted.area.activeGroup.tabViewItems[0].label = "Renamed"

        XCTAssertEqual(mounted.area.activeGroup.tabBar.label(forSegment: 0), "Renamed")
    }

    // MARK: - Closing

    func testTheCloseButtonShowsOverTheHoveredTabAndClosesIt() throws {
        let mounted = mount(tabs: 3)
        defer { mounted.window.close() }
        let group = mounted.area.activeGroup
        let bar = group.tabBar

        bar.mouseMoved(with: mouse(.mouseMoved, at: center(of: bar, tab: 1), in: bar))
        XCTAssertFalse(bar.closeButton.isHidden, "no close button over the hovered tab")
        XCTAssertTrue(
            bar.rect(forTabAt: 1).contains(bar.closeButton.frame),
            "the close button is not on the hovered tab")

        bar.closeButton.performClick(nil)

        XCTAssertEqual(group.tabViewItems.map(\.label), ["Tab 0", "Tab 2"])
        XCTAssertEqual(mounted.recorder.closed.count, 1)
        XCTAssertIdentical(mounted.recorder.closed.first, mounted.probes[1])
    }

    func testClosingTheSelectedTabSelectsTheOneAfterIt() throws {
        let mounted = mount(tabs: 3)
        defer { mounted.window.close() }
        let group = mounted.area.activeGroup
        group.selectedTabViewItemIndex = 1

        group.removeTabViewItem(group.tabViewItems[1])

        XCTAssertEqual(group.tabViewItems[group.selectedTabViewItemIndex].label, "Tab 2")
        XCTAssertIdentical(mounted.area.activeViewController, mounted.probes[2])
    }

    func testTheLastTabOfTheOnlyEditorLeavesItEmptyNotGone() throws {
        let mounted = mount(tabs: 1)
        defer { mounted.window.close() }
        let group = mounted.area.activeGroup

        group.removeTabViewItem(group.tabViewItems[0])
        settle(mounted.window)

        XCTAssertEqual(mounted.area.groups.count, 1)
        XCTAssertTrue(group.tabBar.isHidden, "an editor with no tabs still shows a tab bar")
        XCTAssertNil(mounted.area.activeViewController)
        XCTAssertEqual(mounted.recorder.activated.last.map { $0 == nil }, true)
    }

    // MARK: - Pinning

    func testPinningMovesTheTabToTheFrontAndKeepsTheSelection() throws {
        let mounted = mount(tabs: 3)
        defer { mounted.window.close() }
        let group = mounted.area.activeGroup

        group.setTabPinned(true, at: 2)

        XCTAssertEqual(group.tabViewItems.map(\.label), ["Tab 2", "Tab 0", "Tab 1"])
        XCTAssertTrue(group.isTabPinned(at: 0))
        XCTAssertFalse(group.isTabPinned(at: 1))
        XCTAssertIdentical(group.selectedViewController, mounted.probes[2])

        group.setTabPinned(true, at: 2)
        XCTAssertEqual(
            group.tabViewItems.map(\.label), ["Tab 2", "Tab 1", "Tab 0"],
            "a second pin goes after the first, not before it")

        group.setTabPinned(false, at: 0)
        XCTAssertEqual(group.tabViewItems.map(\.label), ["Tab 1", "Tab 2", "Tab 0"])
        XCTAssertEqual(group.numberOfPinnedTabs, 1)
    }

    func testAPinnedTabHasNoCloseButton() throws {
        let mounted = mount(tabs: 2)
        defer { mounted.window.close() }
        let bar = mounted.area.activeGroup.tabBar
        mounted.area.activeGroup.setTabPinned(true, at: 1)
        settle(mounted.window)

        bar.mouseMoved(with: mouse(.mouseMoved, at: center(of: bar, tab: 0), in: bar))

        XCTAssertEqual(bar.hoveredIndex, 0, "premise: the pinned tab is the hovered one")
        XCTAssertTrue(bar.closeButton.isHidden)
    }

    func testTheMenuPinsAndClosesTheOthersButNotThePinned() throws {
        let mounted = mount(tabs: 4)
        defer { mounted.window.close() }
        let group = mounted.area.activeGroup
        let bar = group.tabBar

        let first = try XCTUnwrap(bar.menu(for: mouse(.rightMouseDown, at: center(of: bar, tab: 3), in: bar)))
        XCTAssertEqual(first.items.first?.title, Self.title("Pin Tab"))
        first.performActionForItem(at: 0)
        XCTAssertEqual(group.tabViewItems.map(\.label), ["Tab 3", "Tab 0", "Tab 1", "Tab 2"])

        let menu = try XCTUnwrap(bar.menu(for: mouse(.rightMouseDown, at: center(of: bar, tab: 2), in: bar)))
        XCTAssertEqual(menu.items.first?.title, Self.title("Pin Tab"))
        let closeOthers = try XCTUnwrap(menu.items.firstIndex { $0.title == Self.title("Close Other Tabs") })
        menu.performActionForItem(at: closeOthers)

        XCTAssertEqual(group.tabViewItems.map(\.label), ["Tab 3", "Tab 1"])
        XCTAssertEqual(mounted.recorder.closed.count, 2)
    }

    // MARK: - Two editors

    /// The premise a tab's content loads on: it has no size in `viewWillAppear`
    /// and its final one in `viewDidAppear` — for a tab opened with a new editor
    /// and for one moved into a new editor, the two paths that size a tab's view
    /// from nothing. A transcript's host loads at `viewDidAppear` for exactly
    /// this; loading at `viewWillAppear` measured every row at a width of zero
    /// (root `CLAUDE.md`, "Size before content").
    func testATabAppearsAtItsFinalSizeAndNotBefore() async throws {
        let mounted = mount(tabs: 2)
        defer { mounted.window.close() }
        let right = ProbeViewController(title: "Right")
        mounted.area.addGroup(with: NSTabViewItem(viewController: right))
        let moved = mounted.probes[1]
        mounted.area.removeGroup(mounted.area.groups[1])
        settle(mounted.window)
        mounted.area.moveTabToOtherGroup(at: 1, of: mounted.area.groups[0])

        for _ in 0..<10 where moved.sizesAtAppearance.count < 2 || right.sizesAtAppearance.isEmpty {
            settle(mounted.window)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        settle(mounted.window)

        XCTAssertEqual(right.sizesAtAppearance.count, 1, "premise: the new editor's tab appeared")
        XCTAssertEqual(right.sizeBeforeAppearance, .zero, "the view had a size before appearing")
        XCTAssertEqual(right.sizesAtAppearance.first, right.view.frame.size)
        XCTAssertEqual(moved.sizesAtAppearance.count, 2, "premise: the moved tab appeared again")
        XCTAssertEqual(moved.sizesAtAppearance.last, moved.view.frame.size)
        XCTAssertEqual(
            moved.view.frame.width, frame(of: mounted.area.groups[1]).width, accuracy: 1,
            "premise: the tab is in the new, halved editor")
    }

    func testASecondEditorOpensOnTheRightAtHalfTheWidth() throws {
        let mounted = mount(tabs: 1)
        defer { mounted.window.close() }

        let right = ProbeViewController(title: "Right")
        let group = try XCTUnwrap(
            mounted.area.addGroup(with: NSTabViewItem(viewController: right)))
        settle(mounted.window)

        let groups = mounted.area.groups
        XCTAssertEqual(groups.count, 2)
        XCTAssertIdentical(groups[1], group)
        XCTAssertIdentical(mounted.area.activeGroup, group)
        XCTAssertIdentical(mounted.recorder.activated.last ?? nil, right)
        let left = frame(of: groups[0])
        let rightFrame = frame(of: groups[1])
        XCTAssertLessThan(left.maxX, rightFrame.minX + 0.5, "the editors overlap")
        XCTAssertEqual(left.width, rightFrame.width, accuracy: 1)

        XCTAssertNil(
            mounted.area.addGroup(with: NSTabViewItem(viewController: ProbeViewController(title: "3"))),
            "a third editor opened")
    }

    func testClosingTheLastTabOfTheRightEditorClosesIt() throws {
        let mounted = mount(tabs: 1)
        defer { mounted.window.close() }
        let right = try XCTUnwrap(
            mounted.area.addGroup(
                with: NSTabViewItem(viewController: ProbeViewController(title: "Right"))))

        right.removeTabViewItem(right.tabViewItems[0])

        XCTAssertEqual(mounted.area.groups.count, 1)
        XCTAssertIdentical(mounted.area.activeViewController, mounted.probes[0])
    }

    func testMovingATabToANewEditorKeepsItsViewControllerAndDoesNotCloseIt() throws {
        let mounted = mount(tabs: 2)
        defer { mounted.window.close() }
        let bar = mounted.area.activeGroup.tabBar
        let moved = mounted.probes[1]
        XCTAssertEqual(moved.loads, 1, "premise: the tab was loaded before it moved")

        let menu = try XCTUnwrap(bar.menu(for: mouse(.rightMouseDown, at: center(of: bar, tab: 1), in: bar)))
        let move = try XCTUnwrap(menu.items.firstIndex { $0.title == Self.title("Move to New Editor on Right") })
        menu.performActionForItem(at: move)
        settle(mounted.window)

        XCTAssertEqual(mounted.area.groups.count, 2)
        XCTAssertIdentical(mounted.area.groups[1].selectedViewController, moved)
        XCTAssertEqual(moved.loads, 1, "the moved tab's view was built again")
        XCTAssertTrue(mounted.recorder.closed.isEmpty, "a move was reported as a close")
        XCTAssertNotNil(moved.view.window)
    }

    func testAnEditorsOnlyTabCannotMoveIntoANewEditor() throws {
        let mounted = mount(tabs: 1)
        defer { mounted.window.close() }
        let bar = mounted.area.activeGroup.tabBar

        let menu = try XCTUnwrap(bar.menu(for: mouse(.rightMouseDown, at: center(of: bar, tab: 0), in: bar)))
        let move = try XCTUnwrap(menu.items.first { $0.title == Self.title("Move to New Editor on Right") })

        XCTAssertFalse(move.isEnabled)
    }

    // MARK: - Dragging

    func testDraggingATabAcrossItsNeighboursMovesItAsItGoes() throws {
        let mounted = mount(tabs: 3)
        defer { mounted.window.close() }
        let group = mounted.area.activeGroup
        let bar = group.tabBar

        bar.dragWillBegin(tabAt: 0)
        let over = StubDraggingInfo(source: bar, at: center(of: bar, tab: 2), in: bar)
        XCTAssertEqual(bar.draggingUpdated(over), .move)

        XCTAssertEqual(group.tabViewItems.map(\.label), ["Tab 1", "Tab 2", "Tab 0"])
        XCTAssertEqual(bar.draggedIndex, 2, "the bar lost track of the tab it is dragging")
        XCTAssertTrue(bar.performDragOperation(over))
        bar.dragDidEnd()
        XCTAssertEqual(group.tabViewItems.map(\.label), ["Tab 1", "Tab 2", "Tab 0"])
    }

    func testADraggedTabStaysOutOfThePinnedTabs() throws {
        let mounted = mount(tabs: 3)
        defer { mounted.window.close() }
        let group = mounted.area.activeGroup
        let bar = group.tabBar
        group.setTabPinned(true, at: 0)
        settle(mounted.window)

        bar.dragWillBegin(tabAt: 2)
        _ = bar.draggingUpdated(StubDraggingInfo(source: bar, at: center(of: bar, tab: 0), in: bar))
        bar.dragDidEnd()

        XCTAssertEqual(group.tabViewItems.map(\.label), ["Tab 0", "Tab 2", "Tab 1"])
        XCTAssertEqual(group.numberOfPinnedTabs, 1)
    }

    func testDroppingATabOnTheOtherEditorsBarMovesItToTheGap() throws {
        let mounted = mount(tabs: 2)
        defer { mounted.window.close() }
        let left = mounted.area.activeGroup
        let right = try XCTUnwrap(
            mounted.area.addGroup(
                with: NSTabViewItem(viewController: ProbeViewController(title: "Right"))))
        settle(mounted.window)
        let dragged = mounted.probes[0]

        left.tabBar.dragWillBegin(tabAt: 0)
        // The leading half of the right editor's only tab: the gap before it.
        var point = center(of: right.tabBar, tab: 0)
        point.x -= right.tabBar.rect(forTabAt: 0).width / 4
        let drop = StubDraggingInfo(source: left.tabBar, at: point, in: right.tabBar)
        XCTAssertEqual(right.tabBar.draggingUpdated(drop), .move)
        XCTAssertFalse(right.tabBar.insertionIndicator.isHidden, "no mark where it would drop")
        XCTAssertEqual(left.tabViewItems.count, 2, "a drag over another bar moved the tab early")

        XCTAssertTrue(right.tabBar.performDragOperation(drop))
        left.tabBar.dragDidEnd()

        XCTAssertEqual(right.tabViewItems.map(\.label), ["Tab 0", "Right"])
        XCTAssertEqual(left.tabViewItems.map(\.label), ["Tab 1"])
        XCTAssertIdentical(mounted.area.activeViewController, dragged)
        XCTAssertTrue(right.tabBar.insertionIndicator.isHidden)
        XCTAssertEqual(dragged.loads, 1)
    }

    func testDroppingAnEditorsLastTabOnTheOtherClosesTheFirst() throws {
        let mounted = mount(tabs: 1)
        defer { mounted.window.close() }
        let left = mounted.area.activeGroup
        let right = try XCTUnwrap(
            mounted.area.addGroup(
                with: NSTabViewItem(viewController: ProbeViewController(title: "Right"))))
        settle(mounted.window)

        left.tabBar.dragWillBegin(tabAt: 0)
        let drop = StubDraggingInfo(
            source: left.tabBar, at: center(of: right.tabBar, tab: 0), in: right.tabBar)
        XCTAssertTrue(right.tabBar.performDragOperation(drop))
        left.tabBar.dragDidEnd()

        XCTAssertEqual(mounted.area.groups.count, 1)
        XCTAssertIdentical(mounted.area.groups[0], right)
        XCTAssertEqual(right.tabViewItems.count, 2)
    }

    func testDroppingATabOnTheTrailingHalfOfItsEditorSplitsIt() throws {
        let mounted = mount(tabs: 2)
        defer { mounted.window.close() }
        let group = mounted.area.activeGroup
        let content = group.view

        group.tabBar.dragWillBegin(tabAt: 0)
        let leading = StubDraggingInfo(
            source: group.tabBar, at: NSPoint(x: content.bounds.width * 0.25, y: 200), in: content)
        XCTAssertEqual(content.draggingUpdated(leading), [], "the leading half took a drop")
        let trailing = StubDraggingInfo(
            source: group.tabBar, at: NSPoint(x: content.bounds.width * 0.75, y: 200), in: content)
        XCTAssertEqual(content.draggingUpdated(trailing), .move)
        XCTAssertTrue(content.performDragOperation(trailing))
        group.tabBar.dragDidEnd()
        settle(mounted.window)

        XCTAssertEqual(mounted.area.groups.count, 2)
        XCTAssertIdentical(mounted.area.groups[1].selectedViewController, mounted.probes[0])
        XCTAssertEqual(group.tabViewItems.map(\.label), ["Tab 1"])
    }

    // MARK: - The divider

    /// The property the transcript leans on without knowing it is in a split: a
    /// divider drag is a live resize for every view under it, begun and ended.
    func testADividerDragIsALiveResizeForTheTabsContent() throws {
        let mounted = mount(tabs: 1)
        defer { mounted.window.close() }
        mounted.area.addGroup(with: NSTabViewItem(viewController: ProbeViewController(title: "R")))
        settle(mounted.window)
        let probe = mounted.probes[0].probe
        let split = mounted.area.splitView
        let divider = frame(of: mounted.area.groups[0]).maxX + split.dividerThickness / 2
        probe.log = []

        for (type, x) in [
            (NSEvent.EventType.leftMouseDragged, divider + 30), (.leftMouseDragged, divider + 60),
            (.leftMouseUp, divider + 60),
        ] {
            NSApp.postEvent(mouse(type, at: NSPoint(x: x, y: 200), in: split), atStart: false)
        }
        split.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: divider, y: 200), in: split))

        XCTAssertEqual(probe.log.first, "start", "the drag did not begin a live resize")
        XCTAssertEqual(probe.log.last, "end", "the drag did not end its live resize")
        let sizes = probe.log.dropFirst().dropLast()
        XCTAssertFalse(sizes.isEmpty, "premise: the divider moved")
        XCTAssertTrue(
            sizes.allSatisfy { $0.hasSuffix("live") }, "a frame of the drag was not live: \(sizes)")
        XCTAssertEqual(
            frame(of: mounted.area.groups[0]).maxX, divider + 60 - split.dividerThickness / 2,
            accuracy: 1)
    }

    // MARK: - Following the reader

    func testTheEditorTakingTheFocusBecomesActive() throws {
        let mounted = mount(tabs: 1)
        defer { mounted.window.close() }
        let rightProbe = ProbeViewController(title: "Right")
        mounted.area.addGroup(with: NSTabViewItem(viewController: rightProbe))
        settle(mounted.window)
        XCTAssertIdentical(mounted.area.activeViewController, rightProbe, "premise")

        mounted.window.makeFirstResponder(mounted.probes[0].field)

        XCTAssertIdentical(mounted.area.activeGroup, mounted.area.groups[0])
        XCTAssertIdentical(mounted.recorder.activated.last ?? nil, mounted.probes[0])
    }

    /// A click on something that takes no focus still moves the active editor.
    /// A middle click, because it is the button a window does nothing with:
    /// `NSApp.sendEvent` of a left press would ask for the window to be made key.
    func testAClickInTheOtherEditorMakesItActive() throws {
        let mounted = mount(tabs: 1)
        defer { mounted.window.close() }
        let rightProbe = ProbeViewController(title: "Right")
        mounted.area.addGroup(with: NSTabViewItem(viewController: rightProbe))
        settle(mounted.window)
        let left = mounted.probes[0].probe

        NSApp.sendEvent(
            mouse(.otherMouseDown, at: NSPoint(x: left.bounds.midX, y: left.bounds.midY), in: left))

        XCTAssertIdentical(mounted.area.activeViewController, mounted.probes[0])
    }

    // MARK: - Harness

    private struct Mounted {
        let window: NSWindow
        let area: EditorAreaViewController
        let recorder: Recorder
        let probes: [ProbeViewController]
    }

    private func mount(tabs: Int) -> Mounted {
        let window = TestWindow.make(contentSize: Self.size)
        let area = EditorAreaViewController()
        let recorder = Recorder()
        area.delegate = recorder
        window.contentViewController = area
        // Assigning a content view controller sizes the window to its view.
        TestWindow.park(window, contentSize: Self.size)
        let probes = (0..<tabs).map { ProbeViewController(title: "Tab \($0)") }
        for probe in probes {
            area.activeGroup.addTabViewItem(NSTabViewItem(viewController: probe))
        }
        settle(window)
        return Mounted(window: window, area: area, recorder: recorder, probes: probes)
    }

    /// What the tab menu calls an item, in whatever language the machine runs in.
    private static func title(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .module)
    }

    /// A group's frame in the split view's coordinates. Not `view.frame`: the
    /// split view controller may put a container of its own around each item's
    /// view, which makes `frame` relative to that.
    private func frame(of group: EditorGroupViewController) -> NSRect {
        group.view.convert(group.view.bounds, to: group.area?.splitView)
    }

    private func settle(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0))
    }

    /// Where every layer under `layer` is on screen right now: the presentation
    /// frame, whatever is moving it.
    private func layerFrames(of layer: CALayer) -> [NSRect] {
        [(layer.presentation() ?? layer).frame] + (layer.sublayers ?? []).flatMap { layerFrames(of: $0) }
    }

    private func center(of bar: EditorTabBar, tab: Int) -> NSPoint {
        let rect = bar.rect(forTabAt: tab)
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in view: NSView) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
            clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }
}

/// What the area told its delegate.
@MainActor
private final class Recorder: EditorAreaViewControllerDelegate {

    var activated: [NSViewController?] = []
    var closed: [NSViewController] = []

    func editorArea(
        _ editorArea: EditorAreaViewController, didActivate viewController: NSViewController?
    ) {
        activated.append(viewController)
    }

    func editorArea(
        _ editorArea: EditorAreaViewController, willClose viewController: NSViewController
    ) {
        closed.append(viewController)
    }
}

/// A tab's content: a view that logs live resizes, and a field to focus.
@MainActor
private final class ProbeViewController: NSViewController {

    let probe = LiveResizeProbe()
    let field = NSTextField(string: "")
    private(set) var loads = 0
    /// The view's size each time it appeared — what a view controller that loads
    /// on appearance would load at.
    private(set) var sizesAtAppearance: [NSSize] = []
    /// The view's size the first time it was about to appear.
    private(set) var sizeBeforeAppearance: NSSize?

    init(title: String) {
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("code-only")
    }

    override func loadView() {
        probe.addSubview(field)
        field.frame = NSRect(x: 10, y: 10, width: 100, height: 22)
        view = probe
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loads += 1
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        if sizeBeforeAppearance == nil { sizeBeforeAppearance = view.frame.size }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        sizesAtAppearance.append(view.frame.size)
    }
}

/// Logs `start`, one `<width> live|still` per frame change, and `end`.
private final class LiveResizeProbe: NSView {

    var log: [String] = []

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        log.append("start")
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        log.append("end")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        log.append("\(Int(newSize.width)) \(inLiveResize ? "live" : "still")")
    }
}
