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
        mounted.area.activeGroup.previewTabViewItem = mounted.area.activeGroup.tabViewItems[1]
        settle(mounted.window)

        let rects = (0..<3).map { bar.rect(forTabAt: $0) }
        XCTAssertGreaterThan(bar.bounds.width, 300, "premise: the bar was laid out")
        XCTAssertEqual(rects[0].minX, bar.bounds.minX, accuracy: 0.5)
        XCTAssertEqual(rects[0].maxX, rects[1].minX, accuracy: 0.5)
        XCTAssertEqual(rects[1].maxX, rects[2].minX, accuracy: 0.5)
        XCTAssertEqual(rects[2].maxX, bar.bounds.maxX, accuracy: 0.5)
        XCTAssertEqual(
            rects[0].width, rects[1].width, accuracy: 0.5, "the temporary tab is not as wide as the others")
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

        /// Grey near the trailing end of a tab's capsule, where no title reaches,
        /// clear of the pin's halo.
        func grey(atTab index: Int) async throws -> CGFloat {
            try await WindowCapture.waitForFrames(of: mounted.window, spanning: 0.2)
            let rep = try await WindowCapture.bitmap(of: bar)
            let tab = bar.rect(forTabAt: index)
            let color = try XCTUnwrap(
                rep.colorAt(x: Int(tab.maxX - 34), y: Int(tab.midY))?.usingColorSpace(.sRGB))
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
        XCTAssertNil(mounted.area.activeViewController)
        XCTAssertEqual(mounted.recorder.activated.last.map { $0 == nil }, true)
    }

    /// The bar is where the tabs are: there with one, the content under it, and
    /// gone with the last — back where it was with the next.
    func testTheTabBarShowsWhileThereAreTabs() throws {
        let mounted = mount(tabs: 1)
        defer { mounted.window.close() }
        let group = mounted.area.activeGroup
        let content = try XCTUnwrap(mounted.probes[0].view.superview, "premise: the tab's view is mounted")

        XCTAssertFalse(group.tabBar.isHidden, "one tab shows no bar")
        let bar = group.tabBar.convert(group.tabBar.bounds, to: group.view)
        XCTAssertGreaterThan(bar.height, 0, "premise: the bar was laid out")
        XCTAssertLessThanOrEqual(
            content.convert(content.bounds, to: group.view).maxY, bar.minY, "the content runs under the bar")

        group.removeTabViewItem(group.tabViewItems[0])
        settle(mounted.window)

        XCTAssertTrue(group.tabViewItems.isEmpty, "premise: the tab closed")
        XCTAssertTrue(group.tabBar.isHidden, "an editor with no tabs shows an empty bar")

        group.addTabViewItem(NSTabViewItem(viewController: ProbeViewController(title: "Next")))
        settle(mounted.window)
        XCTAssertFalse(group.tabBar.isHidden)
        XCTAssertEqual(group.tabBar.convert(group.tabBar.bounds, to: group.view), bar, "the bar came back elsewhere")
    }

    /// Under a window's toolbar the bar hangs below it, where the titlebar does
    /// not take the clicks.
    func testTheTabBarStartsBelowTheSafeArea() throws {
        let mounted = mount(tabs: 1)
        defer { mounted.window.close() }
        let group = mounted.area.activeGroup
        mounted.window.styleMask.insert(.fullSizeContentView)
        mounted.window.toolbar = NSToolbar(identifier: "EditorAreaTests")
        TestWindow.park(mounted.window, contentSize: Self.size)
        settle(mounted.window)

        let inset = group.view.safeAreaInsets.top
        XCTAssertGreaterThan(inset, 0, "premise: the editor reaches under the titlebar")
        let bar = group.tabBar.convert(group.tabBar.bounds, to: group.view)
        XCTAssertLessThanOrEqual(bar.maxY, group.view.bounds.maxY - inset, "the bar is under the titlebar")
    }

    // MARK: - Pinning

    /// Xcode's pin: on the hovered tab's trailing end, hollow on the temporary tab
    /// and filled on any other, beside the close button on every tab.
    func testThePinShowsOnTheHoveredTabHollowWhileItIsTemporary() throws {
        let mounted = mount(tabs: 1)
        defer { mounted.window.close() }
        let group = mounted.area.activeGroup
        group.previewTabViewItem = NSTabViewItem(viewController: ProbeViewController(title: "Look"))
        settle(mounted.window)
        let bar = group.tabBar
        XCTAssertTrue(bar.pinButton.isHidden, "premise: no tab is hovered")

        bar.mouseMoved(with: mouse(.mouseMoved, at: center(of: bar, tab: 1), in: bar))
        XCTAssertFalse(bar.pinButton.isHidden, "no pin on the hovered tab")
        XCTAssertFalse(bar.closeButton.isHidden, "a tab with a pin lost its close button")
        let tab = bar.rect(forTabAt: 1)
        XCTAssertTrue(tab.contains(bar.pinButton.frame), "the pin is not on the hovered tab")
        XCTAssertGreaterThan(bar.pinButton.frame.midX, tab.midX, "the pin is not at the trailing end")
        XCTAssertEqual(bar.pinButton.image?.accessibilityDescription, Self.title("Pin Tab"))

        bar.mouseMoved(with: mouse(.mouseMoved, at: center(of: bar, tab: 0), in: bar))
        XCTAssertTrue(bar.rect(forTabAt: 0).contains(bar.pinButton.frame), "the pin did not follow the pointer")
        XCTAssertEqual(bar.pinButton.image?.accessibilityDescription, Self.title("Unpin Tab"))

        bar.mouseExited(with: mouse(.mouseMoved, at: .zero, in: bar))
        XCTAssertTrue(bar.pinButton.isHidden, "the pin stayed with no tab hovered")
    }

    /// The temporary tab's pin pins it, as a double-click does; a pinned tab's
    /// makes it the temporary tab, and the one that was is pinned.
    func testThePinPinsTheTemporaryTabAndUnpinsAPinnedOne() throws {
        let mounted = mount(tabs: 1)
        defer { mounted.window.close() }
        let group = mounted.area.activeGroup
        let look = NSTabViewItem(viewController: ProbeViewController(title: "Look"))
        group.previewTabViewItem = look
        settle(mounted.window)
        let bar = group.tabBar

        bar.mouseMoved(with: mouse(.mouseMoved, at: center(of: bar, tab: 1), in: bar))
        bar.pinButton.performClick(nil)
        XCTAssertNil(group.previewTabViewItem, "the pin did not pin the temporary tab")
        XCTAssertEqual(bar.items.map(\.isPreview), [false, false])
        XCTAssertEqual(bar.pinButton.image?.accessibilityDescription, Self.title("Unpin Tab"), "the pin is not filled")

        group.previewTabViewItem = NSTabViewItem(viewController: ProbeViewController(title: "Next"))
        bar.mouseMoved(with: mouse(.mouseMoved, at: center(of: bar, tab: 0), in: bar))
        bar.pinButton.performClick(nil)
        XCTAssertIdentical(group.previewTabViewItem, group.tabViewItems[0], "unpinning did not make it temporary")
        XCTAssertEqual(bar.items.map(\.isPreview), [true, false, false])
        XCTAssertEqual(group.tabViewItems.map(\.label), ["Tab 0", "Look", "Next"], "unpinning moved or closed a tab")
    }

    /// The menu's item is the pin's, and Close Other Tabs closes pinned tabs too:
    /// a pin keeps a tab from being replaced, not from being closed on purpose.
    func testTheMenuPinsAndClosesEveryOtherTab() throws {
        let mounted = mount(tabs: 3)
        defer { mounted.window.close() }
        let group = mounted.area.activeGroup
        let bar = group.tabBar
        group.previewTabViewItem = group.tabViewItems[2]

        let first = try XCTUnwrap(bar.menu(for: mouse(.rightMouseDown, at: center(of: bar, tab: 2), in: bar)))
        XCTAssertEqual(first.items.first?.title, Self.title("Pin Tab"))
        first.performActionForItem(at: 0)
        XCTAssertNil(group.previewTabViewItem)
        XCTAssertEqual(group.tabViewItems.map(\.label), ["Tab 0", "Tab 1", "Tab 2"], "pinning moved the tab")

        let menu = try XCTUnwrap(bar.menu(for: mouse(.rightMouseDown, at: center(of: bar, tab: 1), in: bar)))
        XCTAssertEqual(menu.items.first?.title, Self.title("Unpin Tab"))
        let closeOthers = try XCTUnwrap(menu.items.firstIndex { $0.title == Self.title("Close Other Tabs") })
        menu.performActionForItem(at: closeOthers)

        XCTAssertEqual(group.tabViewItems.map(\.label), ["Tab 1"])
        XCTAssertEqual(mounted.recorder.closed.count, 2)
    }

    // MARK: - Two editors

    /// The premise a tab's content loads on: it has no size in `viewWillAppear`
    /// and its final one in `viewDidAppear` — for a tab opened with a new editor
    /// and for one moved into a new editor, the two paths that size a tab's view
    /// from nothing. A transcript's host loads at `viewDidAppear` for exactly
    /// this; loading at `viewWillAppear` measured every row at a width of zero
    /// (`macos/CLAUDE.md`, "Size before content").
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
        // Short of the edge: a pull to it would start a real drag session, which a
        // test cannot (this directory's `CLAUDE.md`).
        for pull: CGFloat in [-10, 6, 11] {
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

    /// Out of the bar, the tab goes with the drag session: its place stays open
    /// while the drag is still over the bar, and the tabs it left close up once
    /// the drag leaves; back from a drag that dropped nowhere, it takes its place
    /// again.
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
        XCTAssertEqual(bar.gapIndex, 1, "the drag begins over the bar, and its place did not stay open")
        XCTAssertEqual(last.frame, rest, "the tabs closed up while the drag was still over the bar")

        bar.draggingExited(nil)
        try await WindowCapture.waitForFrames(of: mounted.window, spanning: 0.5)
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

    // MARK: - Drops from outside

    func testSomethingDroppedOnTheBarOpensInTheGap() throws {
        let mounted = mount(tabs: 2)
        defer { mounted.window.close() }
        mounted.area.registerForDraggedTypes([.string])
        let bar = mounted.area.activeGroup.tabBar
        var point = center(of: bar, tab: 0)
        point.x -= bar.rect(forTabAt: 0).width / 4

        let drop = StubDraggingInfo(source: nil, at: point, in: bar, pasteboard: pasteboard("Dropped"))
        XCTAssertEqual(bar.draggingUpdated(drop), .copy)
        XCTAssertEqual(bar.gapIndex, 0, "no gap where it would drop")
        XCTAssertTrue(bar.performDragOperation(drop))

        XCTAssertEqual(mounted.area.activeGroup.tabViewItems.map(\.label), ["Dropped", "Tab 0", "Tab 1"])
        XCTAssertEqual(mounted.area.activeViewController?.title, "Dropped")
        XCTAssertNil(bar.gapIndex)
    }

    func testSomethingDroppedOnTheTrailingHalfOpensInANewEditor() throws {
        let mounted = mount(tabs: 1)
        defer { mounted.window.close() }
        mounted.area.registerForDraggedTypes([.string])
        let content = mounted.area.activeGroup.view

        let drop = StubDraggingInfo(
            source: nil, at: NSPoint(x: content.bounds.width * 0.75, y: 200), in: content,
            pasteboard: pasteboard("Dropped"))
        XCTAssertEqual(content.draggingUpdated(drop), .copy)
        XCTAssertTrue(content.performDragOperation(drop))
        settle(mounted.window)

        XCTAssertEqual(mounted.area.groups.map { $0.tabViewItems.map(\.label) }, [["Tab 0"], ["Dropped"]])
    }

    func testARefusedDropOpensNothingAndLeavesNoGap() throws {
        let mounted = mount(tabs: 2)
        defer { mounted.window.close() }
        mounted.area.registerForDraggedTypes([.string])
        let bar = mounted.area.activeGroup.tabBar

        let drop = StubDraggingInfo(
            source: nil, at: center(of: bar, tab: 1), in: bar, pasteboard: pasteboard(Recorder.refused))
        XCTAssertEqual(bar.draggingUpdated(drop), .copy)
        XCTAssertFalse(bar.performDragOperation(drop))

        XCTAssertEqual(mounted.area.activeGroup.tabViewItems.map(\.label), ["Tab 0", "Tab 1"])
        XCTAssertNil(bar.gapIndex)
    }

    func testATypeNotRegisteredIsNotTaken() throws {
        let mounted = mount(tabs: 2)
        defer { mounted.window.close() }
        let bar = mounted.area.activeGroup.tabBar
        let content = mounted.area.activeGroup.view

        let overBar = StubDraggingInfo(source: nil, at: center(of: bar, tab: 0), in: bar, pasteboard: pasteboard("x"))
        let overContent = StubDraggingInfo(
            source: nil, at: NSPoint(x: 100, y: 200), in: content, pasteboard: pasteboard("x"))
        XCTAssertEqual(bar.draggingUpdated(overBar), [])
        XCTAssertEqual(content.draggingUpdated(overContent), [])
    }

    /// A private pasteboard holding `string`: what a drag from outside carries.
    private func pasteboard(_ string: String) -> NSPasteboard {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        return pasteboard
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

    // MARK: - Temporary tab

    /// Xcode's: a look replaces the last look where it stands, and the tab it
    /// replaces is closed like any other.
    func testATemporaryTabIsReplacedWhereItStands() throws {
        let mounted = mount(tabs: 2)
        defer { mounted.window.close() }
        let group = mounted.area.activeGroup
        let first = ProbeViewController(title: "Look 1")

        group.previewTabViewItem = NSTabViewItem(viewController: first)
        group.selectedTabViewItemIndex = 0
        group.previewTabViewItem = NSTabViewItem(viewController: ProbeViewController(title: "Look 2"))

        XCTAssertEqual(group.tabViewItems.map(\.label), ["Tab 0", "Tab 1", "Look 2"])
        XCTAssertEqual(group.selectedTabViewItemIndex, 2)
        XCTAssertTrue(mounted.recorder.closed.contains { $0 === first }, "the replaced tab was not closed")
        XCTAssertEqual(group.tabBar.items.map(\.isPreview), [false, false, true])
    }

    func testDoubleClickingTheTemporaryTabKeepsIt() throws {
        let mounted = mount(tabs: 1)
        defer { mounted.window.close() }
        let group = mounted.area.activeGroup
        group.previewTabViewItem = NSTabViewItem(viewController: ProbeViewController(title: "Look"))
        settle(mounted.window)

        let bar = group.tabBar
        let point = center(of: bar, tab: 1)
        bar.mouseDown(with: mouse(.leftMouseDown, at: point, in: bar, clicks: 2))
        bar.mouseUp(with: mouse(.leftMouseUp, at: point, in: bar, clicks: 2))

        XCTAssertNil(group.previewTabViewItem)
        XCTAssertEqual(bar.items.map(\.isPreview), [false, false])
        group.previewTabViewItem = NSTabViewItem(viewController: ProbeViewController(title: "Next"))
        XCTAssertEqual(group.tabViewItems.map(\.label), ["Tab 0", "Look", "Next"])
    }

    // MARK: - History

    /// Xcode's: back and forward go through what the editor showed, selecting a
    /// tab that is still open — every tab is known by the identifier AppKit gives
    /// it — and a new step spends what was ahead.
    func testBackAndForwardSelectWhatTheEditorShowed() throws {
        let mounted = mount(tabs: 3)
        defer { mounted.window.close() }
        let group = mounted.area.activeGroup
        XCTAssertTrue(group.canGoBack, "premise: each tab added was shown")
        XCTAssertFalse(group.canGoForward)

        group.goBack()
        XCTAssertEqual(group.selectedTabViewItemIndex, 1)
        XCTAssertIdentical(mounted.recorder.activated.last ?? nil, mounted.probes[1], "going back was not reported")
        group.goBack()
        XCTAssertEqual(group.selectedTabViewItemIndex, 0)
        XCTAssertFalse(group.canGoBack)
        XCTAssertTrue(group.canGoForward)

        group.goForward()
        XCTAssertEqual(group.selectedTabViewItemIndex, 1)
        XCTAssertTrue(group.canGoForward)

        group.selectedTabViewItemIndex = 0
        XCTAssertFalse(group.canGoForward, "a new step left the old way forward")
        group.goBack()
        XCTAssertEqual(group.selectedTabViewItemIndex, 1)
        XCTAssertEqual(
            group.tabViewItems.map(\.label), ["Tab 0", "Tab 1", "Tab 2"], "going back opened or moved a tab")
    }

    /// The temporary tab's looks are history: going back to one it replaced opens
    /// it again, from the delegate, in the temporary tab — replacing the look it
    /// went back from, which going forward opens again the same way.
    func testGoingBackReopensWhatTheTemporaryTabReplaced() throws {
        let mounted = mount(tabs: 1)
        defer { mounted.window.close() }
        let group = mounted.area.activeGroup

        group.previewTabViewItem = Self.tab("Look 1")
        group.previewTabViewItem = Self.tab("Look 2")
        XCTAssertEqual(group.tabViewItems.map(\.label), ["Tab 0", "Look 2"], "premise: the look was replaced")

        group.goBack()
        XCTAssertEqual(group.tabViewItems.map(\.label), ["Tab 0", "Look 1"])
        XCTAssertEqual(group.selectedTabViewItemIndex, 1)
        XCTAssertIdentical(group.previewTabViewItem, group.tabViewItems[1], "it did not open as the temporary tab")
        XCTAssertTrue(group.canGoForward)

        group.goForward()
        XCTAssertEqual(group.tabViewItems.map(\.label), ["Tab 0", "Look 2"])
        XCTAssertTrue(group.canGoBack)
        XCTAssertFalse(group.canGoForward)
    }

    /// What the host can no longer show is passed over, and forgotten.
    func testHistoryPassesOverWhatCannotBeShownAnyMore() throws {
        let mounted = mount(tabs: 1)
        defer { mounted.window.close() }
        let group = mounted.area.activeGroup

        group.previewTabViewItem = Self.tab("Look 1")
        group.previewTabViewItem = Self.tab(Recorder.refused)
        group.previewTabViewItem = Self.tab("Look 2")

        group.goBack()
        XCTAssertEqual(group.tabViewItems.map(\.label), ["Tab 0", "Look 1"])
        group.goForward()
        XCTAssertEqual(group.tabViewItems.map(\.label), ["Tab 0", "Look 2"], "forward went somewhere else")
        XCTAssertFalse(group.canGoForward)

        // Back past the one forgotten, to the tab first shown — still open.
        group.goBack()
        group.goBack()
        XCTAssertEqual(group.selectedTabViewItemIndex, 0)
        XCTAssertFalse(group.canGoBack, "the refused look was not forgotten")
    }

    // MARK: - Commands

    /// Back and forward are the area's responder actions, aimed at the active
    /// editor, and enabled — for a menu item and a toolbar item alike — while that
    /// editor has somewhere to go.
    func testBackAndForwardAreTheAreasCommandsForTheActiveEditor() throws {
        let mounted = mount(tabs: 2)
        defer { mounted.window.close() }
        let area = mounted.area
        let back = NSMenuItem(title: "Back", action: #selector(EditorAreaViewController.goBack(_:)), keyEquivalent: "")
        let toolbar = ToolbarWithItem(target: area, action: #selector(EditorAreaViewController.goForward(_:)))
        mounted.window.toolbar = toolbar.toolbar
        let forward = try XCTUnwrap(toolbar.toolbar.items.first, "premise: the toolbar shows its item")
        XCTAssertTrue(area.validateUserInterfaceItem(back), "premise: the second tab was shown after the first")
        toolbar.toolbar.validateVisibleItems()
        XCTAssertFalse(forward.isEnabled, "forward with nothing ahead")

        // Up the responder chain from inside a tab, as a nil-targeted item goes.
        XCTAssertTrue(mounted.probes[1].field.tryToPerform(#selector(EditorAreaViewController.goBack(_:)), with: nil))
        XCTAssertEqual(area.activeGroup.selectedTabViewItemIndex, 0, "back went nowhere")
        XCTAssertFalse(area.validateUserInterfaceItem(back))
        toolbar.toolbar.validateVisibleItems()
        XCTAssertTrue(forward.isEnabled, "the toolbar item did not follow the history")

        area.goForward(nil)
        XCTAssertEqual(area.activeGroup.selectedTabViewItemIndex, 1)
    }

    /// Xcode's ⌘W: the active editor's selected tab, through `willClose`; with
    /// no tab left, the window.
    func testCloseTabClosesTheSelectedTabThenTheWindow() throws {
        let mounted = mount(tabs: 2)
        defer { mounted.window.close() }
        let area = mounted.area
        let closer = WindowCloseRecorder()
        mounted.window.styleMask.insert(.closable)
        mounted.window.delegate = closer
        let close = NSMenuItem(
            title: "Close Tab", action: #selector(EditorAreaViewController.closeTab(_:)), keyEquivalent: "")

        area.closeTab(nil)
        XCTAssertEqual(area.activeGroup.tabViewItems.map(\.label), ["Tab 0"])
        XCTAssertEqual(mounted.recorder.closed.map(\.title), ["Tab 1"], "the tab closed without telling the host")
        area.closeTab(nil)
        XCTAssertTrue(area.activeGroup.tabViewItems.isEmpty)
        XCTAssertEqual(closer.asked, 0, "a tab's close closed the window")

        XCTAssertTrue(area.validateUserInterfaceItem(close), "nothing to close in a window with no tab")
        area.closeTab(nil)
        XCTAssertEqual(closer.asked, 1, "the window was not asked to close")
    }

    /// A tab is found by its identifier in whichever editor has it, and brought
    /// forward there; the active editor stays where it is.
    func testSelectingByIdentifierFindsTheTabInEitherEditor() throws {
        let mounted = mount(tabs: 1)
        defer { mounted.window.close() }
        let area = mounted.area
        let left = area.activeGroup
        left.addTabViewItem(Self.tab("a"))
        left.addTabViewItem(Self.tab("b"))
        let right = try XCTUnwrap(area.addGroup(with: Self.tab("c")))
        right.addTabViewItem(Self.tab("d"))
        XCTAssertIdentical(area.activeGroup, right, "premise")

        XCTAssertTrue(area.selectTabViewItem(withIdentifier: "a"))
        XCTAssertEqual(left.selectedTabViewItemIndex, 1)
        XCTAssertIdentical(area.activeGroup, right, "selecting moved the reader to the other editor")
        XCTAssertTrue(area.selectTabViewItem(withIdentifier: "c"))
        XCTAssertEqual(right.selectedTabViewItemIndex, 0)
        XCTAssertFalse(area.selectTabViewItem(withIdentifier: "z"))
        XCTAssertEqual(left.selectedTabViewItemIndex, 1, "a miss changed a selection")
        XCTAssertEqual(right.selectedTabViewItemIndex, 0, "a miss changed a selection")
    }

    /// Selected by identifier with `pinning`, a temporary tab stays; without, it
    /// is still the temporary one.
    func testSelectingByIdentifierPinningKeepsATemporaryTab() {
        let mounted = mount(tabs: 1)
        defer { mounted.window.close() }
        let group = mounted.area.activeGroup
        let look = Self.tab("b")
        group.previewTabViewItem = look

        XCTAssertTrue(mounted.area.selectTabViewItem(withIdentifier: "b"))
        XCTAssertIdentical(group.previewTabViewItem, look, "selecting alone pinned the temporary tab")
        XCTAssertTrue(mounted.area.selectTabViewItem(withIdentifier: "b", pinning: true))
        XCTAssertNil(group.previewTabViewItem, "opening the temporary tab left it temporary")
        XCTAssertEqual(group.tabViewItems.count, 2)
    }

    /// A tab known to the history by its title.
    private static func tab(_ title: String) -> NSTabViewItem {
        let item = NSTabViewItem(viewController: ProbeViewController(title: title))
        item.identifier = title
        return item
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
        group.view.convert(group.view.bounds, to: (group.parent as? NSSplitViewController)?.splitView)
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

    private func mouse(
        _ type: NSEvent.EventType, at point: NSPoint, in view: NSView, clicks: Int = 1
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
            clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)!
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

    /// The string a dropped pasteboard holds for a drop the host refuses.
    static let refused = "refused"

    /// The dropped string, which the tab below is made from.
    func editorArea(
        _ editorArea: EditorAreaViewController, identifierForDrop draggingInfo: NSDraggingInfo
    ) -> Any? {
        draggingInfo.draggingPasteboard.string(forType: .string)
    }

    /// A tab for a dropped title or one the history goes back to, as the host
    /// would make one.
    func editorArea(
        _ editorArea: EditorAreaViewController, tabViewItemWithIdentifier identifier: Any
    ) -> NSTabViewItem? {
        guard let title = identifier as? String, title != Self.refused else { return nil }
        let item = NSTabViewItem(viewController: ProbeViewController(title: title))
        item.identifier = title
        return item
    }
}

/// A window's toolbar with one item, aimed at `target`.
@MainActor
private final class ToolbarWithItem: NSObject, NSToolbarDelegate {

    private static let identifier = NSToolbarItem.Identifier("item")
    let toolbar = NSToolbar(identifier: "test")
    private let target: AnyObject
    private let action: Selector

    init(target: AnyObject, action: Selector) {
        self.target = target
        self.action = action
        super.init()
        toolbar.delegate = self
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.identifier] }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.identifier] }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        item.label = "Item"
        item.target = target
        item.action = action
        return item
    }
}

/// How many times the window was asked to close; never lets it.
@MainActor
private final class WindowCloseRecorder: NSObject, NSWindowDelegate {

    var asked = 0

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        asked += 1
        return false
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
