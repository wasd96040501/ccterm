import AppKit
import XCTest

@testable import AgentSDK
@testable import ccterm

/// Mounts the real `TranscriptViewController` off-screen against a fake
/// history source and asserts the outline actually renders — chiefly
/// that the fixed-width outline `documentView` gets a **non-zero height**
/// under the SPEC §5 Auto Layout setup (width + top constrained, height
/// content-driven), plus that tree-ification / grouping / tool-pairing
/// produce the expected rows and expansion works.
///
/// Opt-in (`*SnapshotTests` filename → skipped by the default suite);
/// run explicitly:
///   make test-unit FILTER=TranscriptOutlineMountSnapshotTests
@MainActor
final class TranscriptOutlineMountSnapshotTests: XCTestCase {

    /// Fake history source — a static seam the store injects. Safe as a
    /// static because snapshot tests run one class per process.
    enum FakeHistory: TranscriptHistoryService {
        nonisolated(unsafe) static var messages: [Message2] = []
        static func loadMessages(sessionId: String) -> [Message2] { messages }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        FakeHistory.messages = Self.fixture()
    }

    func testOutlineRendersWithNonZeroHeight() throws {
        let store = TranscriptStore(historySource: FakeHistory.self)
        let vc = TranscriptViewController(store: store)

        // Mount off-screen and present (present() drives store.load()).
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = vc
        // Setting contentViewController resizes the window to the VC's
        // fitting size (≈ 0 for a pin-only pane); restore the real size
        // so the clip/outline lay out at production-like width.
        window.setContentSize(NSSize(width: 900, height: 760))
        window.contentView?.layoutSubtreeIfNeeded()
        vc.present(sessionId: "fixture")
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        // Tree-ification sanity: 2 markdown paras + 1 tool group + 1 user
        // bubble = 4 roots. Read + Bash are adjacent tool_uses → one group.
        XCTAssertEqual(store.roots.count, 4, "expected 2 paras + group + bubble")
        let group = store.roots.first { $0.isExpandable }
        XCTAssertNotNil(group, "a tool group root must exist")
        XCTAssertEqual(group?.children.count, 2, "two tools in the group")

        let outline = try XCTUnwrap(Self.findOutline(in: vc.view), "no NSOutlineView")

        // Collapsed: only the 4 top-level rows show.
        XCTAssertEqual(outline.numberOfRows, 4, "collapsed top-level row count")

        // THE height check: the fixed-width documentView must have a real
        // height, or the whole pane renders blank.
        XCTAssertGreaterThan(
            outline.frame.height, 0,
            "outline documentView collapsed to zero height")
        XCTAssertGreaterThan(
            outline.frame.width, 0, "outline documentView has zero width")

        // Expansion adds the two tool-header rows.
        let heightBefore = outline.frame.height
        if let groupItem = group {
            outline.expandItem(groupItem)
            outline.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            XCTAssertEqual(outline.numberOfRows, 6, "group expands to 2 children")
            // Content shorter than the viewport keeps the documentView
            // stretched to the clip height, so equality is legitimate
            // here; strict growth (tall body past the viewport) is gated
            // by TranscriptOutlineGeometryTests.
            XCTAssertGreaterThanOrEqual(
                outline.frame.height, heightBefore,
                "expanding a group must never shrink the document height")
        }

        // Visual review artifact: expand the first tool body too, then
        // write a PNG (chevron alignment, column centering, L1-L3 gaps).
        if let tool = group?.children.first {
            outline.expandItem(tool)
            outline.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        // Select everything so the selection band renders into the PNG.
        (outline as? TranscriptOutlineView)?.selection?.selectAllText()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        if let url = Self.writePNG(of: window, name: "TranscriptOutline") {
            let attachment = XCTAttachment(contentsOfFile: url)
            attachment.name = "TranscriptOutline.png"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    // MARK: - Helpers

    /// Renders the window's content view into a PNG under
    /// /tmp/ccterm-screenshots/ and returns the file URL.
    private static func writePNG(of window: NSWindow, name: String) -> URL? {
        guard let content = window.contentView,
            let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
        else { return nil }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        let dir = URL(fileURLWithPath: "/tmp/ccterm-screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).png")
        try? data.write(to: url)
        return url
    }

    private static func findOutline(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView { return outline }
        for sub in view.subviews {
            if let found = findOutline(in: sub) { return found }
        }
        return nil
    }

    /// One `Message2Resolver` across all messages — the resolver is
    /// stateful (it types a `tool_use_result` by pairing the id against
    /// earlier assistant `tool_use`s), same as the production
    /// `SessionHistory` line loop.
    private static func fixture() -> [Message2] {
        let resolver = Message2Resolver()
        func resolve(_ dict: [String: Any]) -> Message2 {
            try! resolver.resolve(dict)
        }
        return [
            resolve([
                "type": "assistant",
                "uuid": UUID().uuidString,
                "session_id": "s",
                "message": [
                    "id": "m1", "type": "message", "role": "assistant",
                    "content": [
                        ["type": "text", "text": "Hello **world**\n\nSecond paragraph."]
                    ],
                ],
            ]),
            resolve([
                "type": "assistant",
                "uuid": UUID().uuidString,
                "session_id": "s",
                "message": [
                    "id": "m2", "type": "message", "role": "assistant",
                    "content": [
                        [
                            "type": "tool_use", "id": "t1", "name": "Read",
                            "input": ["file_path": "/tmp/greeter.swift"],
                        ],
                        [
                            "type": "tool_use", "id": "t2", "name": "Bash",
                            "input": ["command": "echo hi", "description": "greet"],
                        ],
                    ],
                ],
            ]),
            resolve([
                "type": "user", "uuid": UUID().uuidString, "session_id": "s",
                "message": [
                    "role": "user",
                    "content": [
                        ["type": "tool_result", "tool_use_id": "t1", "content": "1\tprint(1)"]
                    ],
                ],
            ]),
            resolve([
                "type": "user", "uuid": UUID().uuidString, "session_id": "s",
                "message": [
                    "role": "user",
                    "content": [
                        ["type": "tool_result", "tool_use_id": "t2", "content": "hi"]
                    ],
                ],
                "tool_use_result": [
                    "stdout": "hi", "stderr": "", "interrupted": false,
                    "isImage": false,
                ],
            ]),
            resolve([
                "type": "user", "uuid": UUID().uuidString, "session_id": "s",
                "message": ["role": "user", "content": "thanks!"],
            ]),
        ]
    }

}
