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
        XCTAssertEqual(group.tabBar.items.count, 3, "the bar does not show every tab")
        XCTAssertEqual(group.tabBar.selectedIndex, 2)
        XCTAssertEqual(group.tabBar.items[1].title, "Tab 1")
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
        XCTAssertEqual(bar.selectedIndex, 0)
        XCTAssertIdentical(mounted.area.activeViewController, mounted.probes[0])
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
        XCTAssertEqual(rects[2].maxX, bar.bounds.maxX, accuracy: 0.5)
        XCTAssertLessThan(
            rects[0].width, rects[1].width, "a pinned tab should be narrower than the rest")
    }

    /// A second editor opening halves the bar, and its tabs go with it.
    func testTheTabsFollowTheBarWhenItResizes() throws {
        let mounted = mount(tabs: 2)
        defer { mounted.window.close() }
        let bar = mounted.area.activeGroup.tabBar
        let before = bar.bounds.width

        _ = try XCTUnwrap(
            mounted.area.addGroup(
                with: NSTabViewItem(viewController: ProbeViewController(title: "Right"))))
        settle(mounted.window)

        XCTAssertLessThan(bar.bounds.width, before * 0.75, "premise: the bar got narrower")
        XCTAssertEqual(try tabView(titled: "Tab 1", in: bar).frame.maxX, bar.bounds.maxX, accuracy: 0.5)
        XCTAssertEqual(try tabView(titled: "Tab 0", in: bar).frame, bar.rect(forTabAt: 0))
    }

    func testRenamingATabRedrawsTheBar() throws {
        let mounted = mount(tabs: 2)
        defer { mounted.window.close() }

        mounted.area.activeGroup.tabViewItems[0].label = "Renamed"

        XCTAssertEqual(mounted.area.activeGroup.tabBar.items[0].title, "Renamed")
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

    /// Under the pointer, the close button sits in a halo of the tab's hover fill,
    /// as Safari's does — black at about 4.7% in the light appearance, white in the
    /// dark — and a press deepens it a step, to about 9.8%. Read as composited at
    /// one point inside the halo clear of the disc, over the hovered tab with the
    /// pointer off the button, on it, and pressing it.
    func testTheCloseButtonHasAHaloUnderThePointerAndADeeperOneWhilePressed() async throws {
        let mounted = mount(tabs: 2)
        defer { mounted.window.close() }
        let bar = mounted.area.activeGroup.tabBar
        let button = bar.closeButton
        bar.mouseMoved(with: mouse(.mouseMoved, at: center(of: bar, tab: 0), in: bar))
        XCTAssertFalse(button.isHidden, "premise: the close button is over the hovered tab")
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)

        /// Grey 0–255 a point and a half in from the button's leading edge, on its
        /// middle line: inside the halo, outside the disc.
        func grey() async throws -> CGFloat {
            try await WindowCapture.waitForFrames(of: mounted.window, spanning: 0.2)
            let rep = try await WindowCapture.bitmap(of: button)
            let color = try XCTUnwrap(rep.colorAt(x: 1, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
            return (color.redComponent + color.greenComponent + color.blueComponent) / 3 * 255
        }

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            mounted.window.appearance = NSAppearance(named: appearance)
            let ink: CGFloat = name == "light" ? 0 : 255
            button.mouseExited(with: mouse(.mouseMoved, at: point, in: button))
            let away = try await grey()

            button.mouseEntered(with: mouse(.mouseMoved, at: point, in: button))
            let hovered = try await grey()
            // Solve `over = away + (ink - away) * alpha` for the halo's alpha.
            XCTAssertEqual(
                (hovered - away) / (ink - away), 0.047, accuracy: 0.015,
                "\(name): not the hover halo — \(away) → \(hovered)")

            button.highlight(true)
            let pressed = try await grey()
            button.highlight(false)
            XCTAssertEqual(
                (pressed - away) / (ink - away), 0.098, accuracy: 0.015,
                "\(name): the press does not deepen it — \(away) → \(pressed)")
        }
    }

    /// The disc is Safari's — 12 points — centred in the button, and the button on
    /// the centre of the glass's leading end. Read off the composited window at its
    /// own resolution: a half-point error is a single pixel there, and would blur
    /// away at one pixel per point. A symbol placed by its alignment rect, a text
    /// baseline's, sat half a point left and low.
    func testTheCloseDiscIsSafarisSizeAndOnTheCentreOfTheTabsEnd() async throws {
        let mounted = mount(tabs: 2)
        defer { mounted.window.close() }
        let window = mounted.window
        let bar = mounted.area.activeGroup.tabBar
        let button = bar.closeButton
        bar.mouseMoved(with: mouse(.mouseMoved, at: center(of: bar, tab: 0), in: bar))
        XCTAssertFalse(button.isHidden, "premise: the close button is over the hovered tab")
        let tab = bar.rect(forTabAt: 0)
        XCTAssertEqual(button.frame.midX, tab.minX + tab.height / 2, "not on the centre of the glass's end")
        XCTAssertEqual(button.frame.midY, tab.midY)

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            try await WindowCapture.waitForFrames(of: window, spanning: 0.2)
            let image = try await WindowCapture.image(of: window)
            // The backing scale, not the capture's width over the frame's: a capture
            // can come back a few pixels wider than the frame, and a scale of 2.004
            // crops a 37-pixel square around a 36-pixel button.
            let scale = window.backingScaleFactor
            let inWindow = button.convert(button.bounds, to: nil)
            let crop = CGRect(
                x: inWindow.minX * scale, y: (window.frame.height - inWindow.maxY) * scale,
                width: inWindow.width * scale, height: inWindow.height * scale)
            XCTAssertEqual(crop, crop.integral, "premise: the button is on whole pixels")
            let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(image.cropping(to: crop)))
            func grey(_ x: Int, _ y: Int) -> CGFloat {
                let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                return ((color?.redComponent ?? 0) + (color?.greenComponent ?? 0) + (color?.blueComponent ?? 0)) / 3
            }
            // Ink: at least a quarter darker than the tab behind it in the light
            // appearance, lighter in the dark — a disc that stayed dark there is one
            // whose colour stopped following the appearance.
            let background = grey(0, 0)
            let sign: CGFloat = name == "light" ? 1 : -1
            let ink = (0..<rep.pixelsHigh).flatMap { y in
                (0..<rep.pixelsWide).filter { sign * (background - grey($0, y)) > 0.25 }.map { (x: $0, y: y) }
            }
            let xs = ink.map(\.x)
            let ys = ink.map(\.y)
            let (minX, maxX) = (try XCTUnwrap(xs.min(), "\(name): the disc was not drawn"), xs.max() ?? 0)
            let (minY, maxY) = (ys.min() ?? 0, ys.max() ?? 0)

            XCTAssertEqual(CGFloat(maxX - minX + 1) / scale, 12, accuracy: 0.5, "\(name): not Safari's 12-point disc")
            XCTAssertEqual(CGFloat(maxY - minY + 1) / scale, 12, accuracy: 0.5, "\(name): not Safari's 12-point disc")
            XCTAssertEqual(
                CGFloat(minX + maxX + 1) / 2, CGFloat(rep.pixelsWide) / 2, accuracy: 0.5,
                "\(name): off centre horizontally")
            XCTAssertEqual(
                CGFloat(minY + maxY + 1) / 2, CGFloat(rep.pixelsHigh) / 2, accuracy: 0.5,
                "\(name): off centre vertically")
        }
    }

    /// A tab under the pointer lights up as Safari's do: a capsule of fill the
    /// glass's size, about 4.7% over the track on a tab that is not selected and a
    /// step lighter, 2.7%, over the glass of the one that is. Read as composited, at
    /// a point inside the capsule clear of the title, before and after.
    func testAHoveredTabLightsUp() async throws {
        let mounted = mount(tabs: 2)
        defer { mounted.window.close() }
        let bar = mounted.area.activeGroup.tabBar
        XCTAssertEqual(bar.selectedIndex, 1, "premise: the second tab is the selected one")

        /// Grey at the trailing end of a tab's capsule, where no title reaches.
        func grey(atTab index: Int) async throws -> CGFloat {
            try await WindowCapture.waitForFrames(of: mounted.window, spanning: 0.2)
            let rep = try await WindowCapture.bitmap(of: bar)
            let tab = bar.rect(forTabAt: index)
            let color = try XCTUnwrap(
                rep.colorAt(x: Int(tab.maxX - 10), y: Int(tab.midY))?.usingColorSpace(.sRGB))
            return (color.redComponent + color.greenComponent + color.blueComponent) / 3 * 255
        }

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            mounted.window.appearance = NSAppearance(named: appearance)
            let ink: CGFloat = name == "light" ? 0 : 255
            for (index, expected) in [(0, 0.047), (1, 0.027)] {
                bar.mouseExited(with: mouse(.mouseMoved, at: .zero, in: bar))
                let away = try await grey(atTab: index)
                bar.mouseMoved(with: mouse(.mouseMoved, at: center(of: bar, tab: index), in: bar))
                let over = try await grey(atTab: index)
                XCTAssertEqual(
                    (over - away) / (ink - away), expected, accuracy: 0.012,
                    "\(name), tab \(index): not the hover fill — \(away) → \(over)")
            }
        }
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

    /// A bar is for choosing between tabs: one tab shows none, and its content
    /// takes the bar's place; a second tab brings the bar back above it.
    func testATabBarShowsOnlyWithMoreThanOneTab() throws {
        let mounted = mount(tabs: 1)
        defer { mounted.window.close() }
        let group = mounted.area.activeGroup
        let content = try XCTUnwrap(mounted.probes[0].view.superview, "premise: the tab's view is mounted")

        XCTAssertTrue(group.tabBar.isHidden, "one tab still shows a bar")
        XCTAssertEqual(
            content.convert(content.bounds, to: group.view).maxY, group.view.bounds.maxY, accuracy: 0.5,
            "the content does not start at the top of the editor")

        group.addTabViewItem(NSTabViewItem(viewController: ProbeViewController(title: "Tab 1")))
        settle(mounted.window)

        XCTAssertFalse(group.tabBar.isHidden)
        let bar = group.tabBar.convert(group.tabBar.bounds, to: group.view)
        XCTAssertLessThanOrEqual(
            content.convert(content.bounds, to: group.view).maxY, bar.minY,
            "the content runs under the bar")

        group.removeTabViewItem(group.tabViewItems[1])
        settle(mounted.window)

        XCTAssertTrue(group.tabBar.isHidden)
        XCTAssertEqual(
            content.convert(content.bounds, to: group.view).maxY, group.view.bounds.maxY, accuracy: 0.5)
    }

    /// Side by side, every editor shows its bar, one tab or not: it is what tells
    /// the two apart. Back to one editor, a lone tab's bar goes again.
    func testEveryEditorShowsItsBarWhileThereAreTwo() throws {
        let mounted = mount(tabs: 1)
        defer { mounted.window.close() }
        let left = mounted.area.activeGroup
        XCTAssertTrue(left.tabBar.isHidden, "premise: one editor with one tab shows no bar")

        let right = try XCTUnwrap(
            mounted.area.addGroup(with: NSTabViewItem(viewController: ProbeViewController(title: "Right"))))
        settle(mounted.window)
        XCTAssertFalse(left.tabBar.isHidden, "the editor already open hid its bar beside another")
        XCTAssertFalse(right.tabBar.isHidden, "the editor opened beside it has no bar")

        mounted.area.removeGroup(right)
        settle(mounted.window)
        XCTAssertEqual(mounted.area.groups.count, 1, "premise: back to one editor")
        XCTAssertTrue(left.tabBar.isHidden, "alone again, one tab still shows a bar")
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

    /// Xcode's drag within a bar: no drag session, the tab stays in the bar under
    /// the pointer, and a neighbour whose middle it passes moves into the place
    /// it left — the move made as it goes, not on release.
    func testDraggingATabAcrossItsNeighboursMovesItAsItGoes() async throws {
        let mounted = mount(tabs: 3)
        defer { mounted.window.close() }
        let group = mounted.area.activeGroup
        let bar = group.tabBar
        let start = center(of: bar, tab: 0)
        // Held by its middle, just short of the last tab's: its trailing edge is
        // past the middles of both neighbours.
        let end = NSPoint(x: bar.rect(forTabAt: 2).midX - 10, y: start.y)

        bar.mouseDown(with: mouse(.leftMouseDown, at: start, in: bar))
        bar.mouseDragged(with: mouse(.leftMouseDragged, at: end, in: bar))

        XCTAssertEqual(group.tabViewItems.map(\.label), ["Tab 1", "Tab 2", "Tab 0"])
        XCTAssertEqual(bar.draggedIndex, 2, "the bar lost track of the tab it is dragging")
        XCTAssertFalse(bar.isDraggedTabOut, "a drag along the bar left it")
        let held = try tabView(titled: "Tab 0", in: bar)
        XCTAssertEqual(held.frame.midX, end.x, accuracy: 0.5, "the tab is not under the pointer")

        // The neighbours slide into the places the tab passed over.
        try await WindowCapture.waitForFrames(of: mounted.window, spanning: 0.5)
        XCTAssertEqual(try tabView(titled: "Tab 1", in: bar).frame, bar.rect(forTabAt: 0))
        XCTAssertEqual(try tabView(titled: "Tab 2", in: bar).frame, bar.rect(forTabAt: 1))

        bar.mouseUp(with: mouse(.leftMouseUp, at: end, in: bar))

        XCTAssertNil(bar.draggedIndex)
        XCTAssertEqual(group.tabViewItems.map(\.label), ["Tab 1", "Tab 2", "Tab 0"])
        try await WindowCapture.waitForFrames(of: mounted.window, spanning: 0.5)
        XCTAssertEqual(held.frame, bar.rect(forTabAt: 2), "let go, the tab did not settle in its place")
    }

    /// The tab stops at the end of the track, and from there it has passed every
    /// neighbour — the ends are places a drag can reach.
    func testATabDraggedPastEitherEndOfTheBarTakesThatEnd() throws {
        let mounted = mount(tabs: 3)
        defer { mounted.window.close() }
        let group = mounted.area.activeGroup
        let bar = group.tabBar
        let start = center(of: bar, tab: 0)

        bar.mouseDown(with: mouse(.leftMouseDown, at: start, in: bar))
        bar.mouseDragged(
            with: mouse(.leftMouseDragged, at: NSPoint(x: bar.bounds.maxX + 50, y: start.y), in: bar))
        XCTAssertEqual(group.tabViewItems.map(\.label), ["Tab 1", "Tab 2", "Tab 0"])
        XCTAssertEqual(try tabView(titled: "Tab 0", in: bar).frame.maxX, bar.bounds.maxX, accuracy: 0.5)

        bar.mouseDragged(
            with: mouse(.leftMouseDragged, at: NSPoint(x: bar.bounds.minX - 50, y: start.y), in: bar))
        bar.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: bar.bounds.minX - 50, y: start.y), in: bar))
        XCTAssertEqual(group.tabViewItems.map(\.label), ["Tab 0", "Tab 1", "Tab 2"])
    }

    /// A tab that lands while another is still sliding — a new tab added as a
    /// dropped one settles — leaves every tab where it now goes, not where the
    /// slide was heading.
    func testATabAddedWhileAnotherSettlesLeavesEveryTabInItsPlace() async throws {
        let mounted = mount(tabs: 3)
        defer { mounted.window.close() }
        let group = mounted.area.activeGroup
        let bar = group.tabBar
        let start = center(of: bar, tab: 0)
        let end = NSPoint(x: bar.rect(forTabAt: 2).midX - 10, y: start.y)
        bar.mouseDown(with: mouse(.leftMouseDown, at: start, in: bar))
        bar.mouseDragged(with: mouse(.leftMouseDragged, at: end, in: bar))
        bar.mouseUp(with: mouse(.leftMouseUp, at: end, in: bar))
        XCTAssertNotEqual(
            try tabView(titled: "Tab 0", in: bar).frame, bar.rect(forTabAt: 2),
            "premise: the dropped tab is still settling")

        group.addTabViewItem(NSTabViewItem(viewController: ProbeViewController(title: "Tab 3")))
        try await WindowCapture.waitForFrames(of: mounted.window, spanning: 0.5)

        XCTAssertEqual(group.tabViewItems.map(\.label), ["Tab 1", "Tab 2", "Tab 0", "Tab 3"])
        for (index, title) in ["Tab 1", "Tab 2", "Tab 0", "Tab 3"].enumerated() {
            XCTAssertEqual(try tabView(titled: title, in: bar).frame, bar.rect(forTabAt: index), title)
        }
    }

    func testAPressThatBarelyMovesSelectsAndDoesNotDrag() throws {
        let mounted = mount(tabs: 3)
        defer { mounted.window.close() }
        let group = mounted.area.activeGroup
        let bar = group.tabBar
        var point = center(of: bar, tab: 0)

        bar.mouseDown(with: mouse(.leftMouseDown, at: point, in: bar))
        point.x += 3
        bar.mouseDragged(with: mouse(.leftMouseDragged, at: point, in: bar))
        XCTAssertNil(bar.draggedIndex, "a hand that shook started a drag")
        bar.mouseUp(with: mouse(.leftMouseUp, at: point, in: bar))

        XCTAssertEqual(group.selectedTabViewItemIndex, 0, "premise: the press landed")
        XCTAssertEqual(group.tabViewItems.map(\.label), ["Tab 0", "Tab 1", "Tab 2"])
        XCTAssertEqual(try tabView(titled: "Tab 0", in: bar).frame, bar.rect(forTabAt: 0))
    }

    /// A tab moves along the track only: a drag down or up short of leaving the
    /// bar leaves it where it runs, so that it goes all at once, as the picture of
    /// its content, rather than drifting off first.
    func testADraggedTabStaysOnTheTrackUntilItLeaves() throws {
        let mounted = mount(tabs: 3)
        defer { mounted.window.close() }
        let bar = mounted.area.activeGroup.tabBar
        let start = center(of: bar, tab: 0)
        let tab = try tabView(titled: "Tab 0", in: bar)
        let rest = bar.rect(forTabAt: 0)

        bar.mouseDown(with: mouse(.leftMouseDown, at: start, in: bar))
        for pull: CGFloat in [-20, 12, 24] {
            bar.mouseDragged(
                with: mouse(.leftMouseDragged, at: NSPoint(x: start.x + 10, y: start.y + pull), in: bar))
            XCTAssertEqual(bar.draggedIndex, 0, "premise: the pull is a drag")
            XCTAssertFalse(bar.isDraggedTabOut, "a pull of \(pull) took the tab out of the bar")
            bar.layoutSubtreeIfNeeded()
            XCTAssertEqual(tab.frame.minY, rest.minY, "a pull of \(pull) moved the tab off the track")
            XCTAssertEqual(tab.frame.minX, rest.minX + 10, accuracy: 0.5, "the tab stopped following the pointer along")
        }
        bar.mouseUp(with: mouse(.leftMouseUp, at: start, in: bar))
    }

    /// A tab pulled out turns into its content: the group hands over the selected
    /// tab's view as drawn, at its size, and nothing for a tab whose view is not
    /// on screen.
    func testAPulledOutTabIsDrawnAsItsContent() throws {
        let mounted = mount(tabs: 2)
        defer { mounted.window.close() }
        let group = mounted.area.activeGroup
        let view = mounted.probes[1].view
        XCTAssertEqual(group.selectedTabViewItemIndex, 1, "premise: the second tab is the one on screen")

        let image = try XCTUnwrap(group.tabBar(group.tabBar, draggingImageForTabAt: 1), "no image")
        XCTAssertEqual(image.size, view.bounds.size)
        let rep = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        let drawn = (0..<rep.pixelsHigh).contains { y in
            (0..<rep.pixelsWide).contains { (rep.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0 }
        }
        XCTAssertTrue(drawn, "the image is blank")

        XCTAssertNil(group.tabBar(group.tabBar, draggingImageForTabAt: 0), "a tab not on screen was drawn")
    }

    func testADraggedTabStaysOutOfThePinnedTabs() throws {
        let mounted = mount(tabs: 3)
        defer { mounted.window.close() }
        let group = mounted.area.activeGroup
        let bar = group.tabBar
        group.setTabPinned(true, at: 0)
        settle(mounted.window)
        let start = center(of: bar, tab: 2)

        bar.mouseDown(with: mouse(.leftMouseDown, at: start, in: bar))
        bar.mouseDragged(
            with: mouse(.leftMouseDragged, at: NSPoint(x: bar.bounds.minX, y: start.y), in: bar))
        bar.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: bar.bounds.minX, y: start.y), in: bar))

        XCTAssertEqual(group.tabViewItems.map(\.label), ["Tab 0", "Tab 2", "Tab 1"])
        XCTAssertEqual(group.numberOfPinnedTabs, 1)
    }

    /// Out of the bar, the tab goes with the drag session and the tabs it left
    /// close up; back from a drag that dropped nowhere, it takes its place again.
    func testATabDraggedOutOfTheBarLeavesNoHole() async throws {
        let mounted = mount(tabs: 3)
        defer { mounted.window.close() }
        let bar = mounted.area.activeGroup.tabBar
        let dragged = try tabView(titled: "Tab 1", in: bar)
        let last = try tabView(titled: "Tab 2", in: bar)
        let rest = last.frame

        bar.dragWillBegin(tabAt: 1)
        try await WindowCapture.waitForFrames(of: mounted.window, spanning: 0.5)

        XCTAssertTrue(dragged.isHidden, "the tab stayed in the bar as well as in the drag")
        XCTAssertEqual(try tabView(titled: "Tab 0", in: bar).frame.maxX, last.frame.minX, accuracy: 0.5)
        XCTAssertEqual(last.frame.maxX, bar.bounds.maxX, accuracy: 0.5, "the tabs did not close up")

        bar.dragDidEnd()
        try await WindowCapture.waitForFrames(of: mounted.window, spanning: 0.5)

        XCTAssertFalse(dragged.isHidden)
        XCTAssertEqual(dragged.frame, bar.rect(forTabAt: 1))
        XCTAssertEqual(last.frame, rest)
    }

    /// Over a bar, the tabs part where the tab would drop, and close again when
    /// it leaves without dropping.
    func testATabOverTheOtherEditorsBarOpensAGapWhereItWouldDrop() async throws {
        let mounted = mount(tabs: 2)
        defer { mounted.window.close() }
        let left = mounted.area.activeGroup
        let right = try XCTUnwrap(
            mounted.area.addGroup(
                with: NSTabViewItem(viewController: ProbeViewController(title: "Right"))))
        settle(mounted.window)
        let resting = try tabView(titled: "Right", in: right.tabBar)
        let rest = resting.frame

        left.tabBar.dragWillBegin(tabAt: 0)
        var point = center(of: right.tabBar, tab: 0)
        point.x -= rest.width / 4
        _ = right.tabBar.draggingUpdated(StubDraggingInfo(source: left.tabBar, at: point, in: right.tabBar))
        try await WindowCapture.waitForFrames(of: mounted.window, spanning: 0.5)

        XCTAssertEqual(right.tabBar.gapIndex, 0)
        XCTAssertEqual(resting.frame.minX, rest.midX, accuracy: 0.5, "no gap opened before the tab")
        XCTAssertEqual(resting.frame.maxX, rest.maxX, accuracy: 0.5)

        right.tabBar.draggingExited(nil)
        left.tabBar.dragDidEnd()
        try await WindowCapture.waitForFrames(of: mounted.window, spanning: 0.5)

        XCTAssertNil(right.tabBar.gapIndex)
        XCTAssertEqual(resting.frame, rest, "the gap stayed open after the tab left")
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
        XCTAssertEqual(right.tabBar.gapIndex, 0, "no gap where it would drop")
        XCTAssertEqual(left.tabViewItems.count, 2, "a drag over another bar moved the tab early")

        XCTAssertTrue(right.tabBar.performDragOperation(drop))
        left.tabBar.dragDidEnd()

        XCTAssertEqual(right.tabViewItems.map(\.label), ["Tab 0", "Right"])
        XCTAssertEqual(left.tabViewItems.map(\.label), ["Tab 1"])
        XCTAssertIdentical(mounted.area.activeViewController, dragged)
        XCTAssertNil(right.tabBar.gapIndex)
        XCTAssertEqual(dragged.loads, 1)
    }

    /// An editor's only tab has no bar to be dragged from, so this is the area's
    /// own rule rather than a gesture: an editor a move emptied closes.
    func testAnEditorAMoveEmptiesCloses() throws {
        let mounted = mount(tabs: 1)
        defer { mounted.window.close() }
        let left = mounted.area.activeGroup
        let right = try XCTUnwrap(
            mounted.area.addGroup(
                with: NSTabViewItem(viewController: ProbeViewController(title: "Right"))))
        settle(mounted.window)

        mounted.area.moveTab(at: 0, of: left, to: right, at: 1)

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
        // AppKit sends `viewDidAppear` on a later turn of the run loop than the one
        // that put the view in the window — not from layout or display, measured —
        // and the area only starts following the reader there. One turn of
        // `settle` delivers it on a fast machine and not on a slow one, so a test
        // that clicked straight away passed here and failed on CI. Waiting for the
        // selected tab to appear waits for the area, which appears in the same
        // pass. The selected tab, which is the last one added.
        wait(for: [probes[probes.count - 1].appeared], timeout: 5)
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

    private func center(of bar: EditorTabBar, tab: Int) -> NSPoint {
        let rect = bar.rect(forTabAt: tab)
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    /// A tab's view, found the way VoiceOver finds it: by the title it is labelled
    /// with. Where it is on screen, as against where it rests (`rect(forTabAt:)`).
    private func tabView(titled title: String, in bar: EditorTabBar) throws -> NSView {
        bar.layoutSubtreeIfNeeded()
        return try XCTUnwrap(bar.subviews.first { $0.accessibilityLabel() == title }, "no tab titled \(title)")
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
        appeared.fulfill()
    }

    /// Fulfilled the first time the view appears, and left fulfilled after.
    let appeared: XCTestExpectation = {
        let appeared = XCTestExpectation(description: "appeared")
        appeared.assertForOverFulfill = false
        return appeared
    }()
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
