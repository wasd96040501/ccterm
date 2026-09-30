import AppKit
import XCTest

@testable import TranscriptKit
@testable import TranscriptKitDemo
@testable import TranscriptWorkspace

/// Two editors side by side, as the window server composited them, in both
/// appearances: `/tmp/transcriptkit-screenshots/EditorArea-{light,dark}.png`.
///
/// **For eyes, not a gate.** Skipped by `make test-kit`; run it with
/// `make test-kit FILTER=EditorAreaSnapshotTests`. What it is for is what
/// `EditorAreaTests` cannot have an opinion on: that the tab bar reads as Xcode's,
/// that a tab's pin reads as Xcode's — hollow on the temporary tab, filled on a
/// pinned one — that the divider is a hairline, and that the
/// find bar sits over its transcript the way Xcode's sits over a source file.
/// Every rectangle under that is asserted there.
@MainActor
final class EditorAreaSnapshotTests: XCTestCase {

    func testEditorArea() async throws {
        let size = NSSize(width: 1100, height: 520)
        let window = TestWindow.make(contentSize: size)
        defer { window.close() }
        let area = EditorAreaViewController()
        window.contentViewController = area
        TestWindow.park(window, contentSize: size)

        let pages = [
            SnapshotPage(title: "Transcript 1", rows: Self.rows),
            SnapshotPage(title: "Transcript 2", rows: Self.rows),
            SnapshotPage(title: "A tab with a longer title", rows: Self.rows),
        ]
        for page in pages {
            area.activeGroup.addTabViewItem(NSTabViewItem(viewController: page))
        }
        area.activeGroup.previewTabViewItem = area.activeGroup.tabViewItems[2]
        area.activeGroup.selectedTabViewItemIndex = 1
        let right = SnapshotPage(title: "Transcript 4", rows: Self.rows)
        let rightGroup = try XCTUnwrap(area.addGroup(with: NSTabViewItem(viewController: right)))
        rightGroup.addTabViewItem(
            NSTabViewItem(viewController: SnapshotPage(title: "Transcript 5", rows: Self.rows)))
        // The right editor comes in with motion; the picture is of it opened.
        let split = area.splitView
        for _ in 0..<100 where split.inLiveResize || rightGroup.view.frame.width > split.arrangedSubviews[1].frame.width
        {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(split.inLiveResize, "premise: the right editor finished opening")
        window.contentView?.layoutSubtreeIfNeeded()

        // The pointer, as a reader would have it: over the left editor's last tab —
        // the temporary one, its pin hollow — and on its close button, and over the
        // right editor's selected tab, its pin filled.
        let left = area.groups[0].tabBar
        left.mouseMoved(with: Self.mouseMoved(at: left.rect(forTabAt: 2), in: left))
        left.closeButton.mouseEntered(with: Self.mouseMoved(at: left.closeButton.frame, in: left))
        let rightBar = rightGroup.tabBar
        rightBar.mouseMoved(with: Self.mouseMoved(at: rightBar.rect(forTabAt: 1), in: rightBar))

        let finding = pages[1]
        finding.findBar.searchString = "claude"
        finding.transcript.find("claude")
        for _ in 0..<20 where finding.transcript.numberOfFindMatches == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        finding.findBar.numberOfMatches = finding.transcript.numberOfFindMatches
        XCTAssertGreaterThan(
            finding.transcript.numberOfFindMatches, 1, "premise: the find has matches to show")

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            window.contentView?.layoutSubtreeIfNeeded()
            try await WindowCapture.waitForFrames(of: window, spanning: 0.4)
            let url = try await WindowCapture.capture(window, named: "EditorArea-\(name)")
            add(XCTAttachment(contentsOfFile: url))
        }
    }

    private static func mouseMoved(at rect: NSRect, in view: NSView) -> NSEvent {
        NSEvent.mouseEvent(
            with: .mouseMoved, location: view.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0)!
    }

    private static let rows: [TranscriptRowContent] = [
        .userMessage("How does Claude keep two editors independent?"),
        .markdown(
            """
            Each editor is its own **view controller**, with its own tabs, and Claude \
            never reaches from one into the other.

            ```swift
            let area = EditorAreaViewController()
            ```
            """),
    ]
}

/// One tab: a find bar over a transcript, the demo's shape without the demo.
@MainActor
private final class SnapshotPage: NSViewController, TranscriptViewDataSource,
    TranscriptViewDelegate
{
    let findBar = FindBarView()
    let transcript = TranscriptView()
    private let rows: [TranscriptRow]

    init(title: String, rows: [TranscriptRowContent]) {
        self.rows = rows.map { TranscriptRow(id: UUID(), content: $0) }
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("code-only")
    }

    override func loadView() {
        let stack = NSStackView(views: [findBar, transcript])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        view = stack
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        transcript.dataSource = self
        transcript.delegate = self
        transcript.maxContentWidth = 620
    }

    /// Mounted and laid out by now, which `viewWillAppear` is not — §6.
    override func viewDidAppear() {
        super.viewDidAppear()
        guard transcript.numberOfRows == 0 else { return }
        view.layoutSubtreeIfNeeded()
        transcript.reloadData()
    }

    func numberOfRows(in transcriptView: TranscriptView) -> Int { rows.count }

    func transcriptView(_ transcriptView: TranscriptView, rowAt row: Int) -> TranscriptRow {
        rows[row]
    }
}
