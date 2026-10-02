import AppKit
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
        mark.activity = activity
        return mark
    }
}
