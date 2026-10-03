import AppKit
import Components
import TranscriptWorkspace
import XCTest

@testable import ccterm

/// The editor's bar as the window shows it (design 08 *Tabs and the +*): the +
/// after the last tab, and each live session's mark — the running arc, coral
/// while it waits for the reader, red when it failed, nothing on the selected
/// New tab. Drawn off screen, so it renders while the display sleeps; the
/// bar's material does not. Review only — `make test-unit
/// FILTER=EditorTabMarksSnapshotTests`, then open
/// `/tmp/ccterm-screenshots/EditorTabMarks-<appearance>.png`.
@MainActor
final class EditorTabMarksSnapshotTests: XCTestCase {

    private static let tabs: [(title: String, activity: SessionState.Activity?)] = [
        ("Row gap and tool rows", .responding),
        ("Fix gutter", .needsInput),
        ("Crash on launch", .failed(message: "exit 1")),
        (SessionTabTitle.draft, nil),
    ]

    func testThePlusAndTheMarks() {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            defer { NSApp.appearance = nil }
            let marks = Marks()
            let area = EditorAreaViewController()
            area.showsNewTabButton = true
            area.delegate = marks
            for tab in Self.tabs {
                let page = NSViewController()
                page.title = tab.title
                page.view = NSView()
                marks.activities[ObjectIdentifier(page)] = tab.activity
                area.activeGroup.addTabViewItem(NSTabViewItem(viewController: page))
            }
            area.activeGroup.selectedTabViewItemIndex = Self.tabs.count - 1
            // Off screen nothing behind the bar is drawn: the window's colour stands in.
            area.view.wantsLayer = true
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                area.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }

            let image = ViewSnapshot.renderViewController(area, size: CGSize(width: 820, height: 96), settle: 0.5)
            let png = ViewSnapshot.writePNG(image, name: "EditorTabMarks-\(suffix)")
            let attachment = XCTAttachment(contentsOfFile: png)
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    // MARK: - Against the design

    /// The sheet's two bars (*Tabs and the +*), at their 524 pt: the + under
    /// the pointer, and the marks in the tabs. Its top 34 pt are the bar.
    func testTheBarsAgainstTheDesign() throws {
        let bars: [(id: String, tabs: [(String, SessionState.Activity?)], selected: Int, hover: Bool)] = [
            ("part-00-bar0", [("Row gap and tool rows", nil), ("Fix gutter overflow", nil)], 0, true),
            (
                "part-01-bar0",
                [
                    ("Smaller run-row summary", .responding), ("Review the diff", .needsInput),
                    ("Nightly build", .failed(message: "exit 1")), (SessionTabTitle.draft, nil),
                ], 1, false
            ),
        ]
        for scheme in DesignParity.Scheme.allCases {
            NSApp.appearance = scheme.appearance
            defer { NSApp.appearance = nil }
            for bar in bars {
                let part = try DesignParity.part(bar.id, scheme)
                let marks = Marks()
                let area = EditorAreaViewController()
                area.showsNewTabButton = true
                area.delegate = marks
                for (title, activity) in bar.tabs {
                    let page = NSViewController()
                    page.title = title
                    page.view = NSView()
                    marks.activities[ObjectIdentifier(page)] = activity
                    area.activeGroup.addTabViewItem(NSTabViewItem(viewController: page))
                }
                area.activeGroup.selectedTabViewItemIndex = bar.selected
                area.view.wantsLayer = true
                scheme.appearance?.performAsCurrentDrawingAppearance {
                    area.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                }
                let image = ViewSnapshot.renderViewController(
                    area, size: CGSize(width: part.width, height: part.height + 40), settle: 0.5
                ) {
                    guard bar.hover, let plus = Self.plus(in: area.view) else { return }
                    plus.mouseEntered(with: Self.enter(plus))
                    plus.displayIfNeeded()
                }
                attach(try DesignParity.write(bar.id, scheme, ours: Self.top(part.height, of: image)))
            }
        }
    }

    private func attach(_ url: URL) {
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The + — the bar's one button labelled New Tab.
    private static func plus(in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.accessibilityLabel() == String(localized: "New Tab") {
            return button
        }
        return view.subviews.lazy.compactMap { plus(in: $0) }.first
    }

    private static func enter(_ view: NSView) -> NSEvent {
        NSEvent.enterExitEvent(
            with: .mouseEntered, location: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil)!
    }

    /// The top `height` pt of `image`.
    private static func top(_ height: CGFloat, of image: NSImage) -> NSImage {
        let size = NSSize(width: image.size.width, height: height)
        let cropped = NSImage(size: size)
        cropped.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(x: 0, y: image.size.height - height, width: size.width, height: height), operation: .copy,
            fraction: 1)
        cropped.unlockFocus()
        return cropped
    }
}

/// The app's own marks, by tab, as `MainSplitViewController` gives them.
@MainActor
private final class Marks: EditorAreaViewControllerDelegate {
    var activities: [ObjectIdentifier: SessionState.Activity] = [:]
    private var views: [ObjectIdentifier: ActivityMarkView] = [:]

    func editorArea(_ editorArea: EditorAreaViewController, indicatorViewFor tabViewItem: NSTabViewItem) -> NSView? {
        guard let page = tabViewItem.viewController, let activity = activities[ObjectIdentifier(page)] else {
            return nil
        }
        let mark = views[ObjectIdentifier(page)] ?? ActivityMarkView()
        views[ObjectIdentifier(page)] = mark
        mark.activity = SidebarActivity(activity)
        return mark
    }
}
