import AppKit
import XCTest

@testable import TranscriptKit
@testable import TranscriptWorkspace

/// Two editors side by side, as the window server composited them, in both
/// appearances: `/tmp/transcriptkit-screenshots/EditorArea-{light,dark}.png`.
///
/// **For eyes, not a gate.** Skipped by `make test-kit`; run it with
/// `make test-kit FILTER=EditorAreaSnapshotTests`. What it is for is what
/// `EditorAreaTests` cannot have an opinion on: that the tab bar reads as Xcode's,
/// that a pinned tab reads as pinned, that the divider is a hairline, and that the
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
            SnapshotPage(title: "Pinned", rows: Self.rows),
            SnapshotPage(title: "Transcript 2", rows: Self.rows),
            SnapshotPage(title: "A tab with a longer title", rows: Self.rows),
        ]
        for page in pages {
            area.activeGroup.addTabViewItem(NSTabViewItem(viewController: page))
        }
        area.activeGroup.setTabPinned(true, at: 0)
        area.activeGroup.selectedTabViewItemIndex = 1
        let right = SnapshotPage(title: "Transcript 4", rows: Self.rows)
        XCTAssertNotNil(area.addGroup(with: NSTabViewItem(viewController: right)))
        window.contentView?.layoutSubtreeIfNeeded()

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

    override func viewWillAppear() {
        super.viewWillAppear()
        guard transcript.numberOfRows == 0 else { return }
        view.layoutSubtreeIfNeeded()
        transcript.reloadData()
    }

    func numberOfRows(in transcriptView: TranscriptView) -> Int { rows.count }

    func transcriptView(_ transcriptView: TranscriptView, rowAt row: Int) -> TranscriptRow {
        rows[row]
    }
}
