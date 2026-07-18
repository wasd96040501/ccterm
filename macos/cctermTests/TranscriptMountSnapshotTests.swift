import AppKit
import XCTest

@testable import AgentSDK
@testable import ccterm

/// Mounts the real `TranscriptViewController` off-screen against a fake
/// history source and asserts the flat table actually renders — chiefly
/// that the full-width table `documentView` gets a **non-zero height**,
/// plus that flattening / grouping produce the expected rows (one
/// group-header row per adjacent tool run, no tool bodies).
///
/// Opt-in (`*SnapshotTests` filename → skipped by the default suite);
/// run explicitly:
///   make test-unit FILTER=TranscriptMountSnapshotTests
@MainActor
final class TranscriptMountSnapshotTests: XCTestCase {

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

    func testTableRendersWithNonZeroHeight() throws {
        let store = TranscriptStore(historySource: FakeHistory.self)
        let vc = TranscriptViewController(store: store)

        // Mount off-screen and present (present() drives store.load()).
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = vc
        // Setting contentViewController resizes the window to the VC's
        // fitting size (≈ 0 for a pin-only pane); restore the real size so
        // the clip/table lay out at production-like width.
        window.setContentSize(NSSize(width: 900, height: 760))
        window.contentView?.layoutSubtreeIfNeeded()
        vc.present(sessionId: "fixture")
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        // Flattening sanity: 2 markdown paras + 1 group header + 1 user
        // bubble = 4 rows. Read + Bash are adjacent tool_uses → one group
        // header (no per-tool rows, no bodies).
        XCTAssertEqual(store.numberOfRows, 4, "expected 2 paras + group header + bubble")
        let groupHeaders = store.rows.filter {
            if case .groupHeader = $0.content { return true }
            return false
        }
        XCTAssertEqual(groupHeaders.count, 1, "one group-header row for the tool run")

        let table = try XCTUnwrap(Self.findTable(in: vc.view), "no NSTableView")
        XCTAssertEqual(table.numberOfRows, 4, "top-level row count")

        // THE height check: the full-width documentView must have a real
        // height, or the whole pane renders blank.
        XCTAssertGreaterThan(
            table.frame.height, 0, "table documentView collapsed to zero height")
        XCTAssertGreaterThan(table.frame.width, 0, "table documentView has zero width")

        // Select everything so the selection band renders into the PNG.
        (table as? TranscriptTableView)?.selection?.selectAllText()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        if let url = Self.writePNG(of: window, name: "Transcript") {
            let attachment = XCTAttachment(contentsOfFile: url)
            attachment.name = "Transcript.png"
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

    private static func findTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for sub in view.subviews {
            if let found = findTable(in: sub) { return found }
        }
        return nil
    }

    /// 2 markdown paras + a 2-tool group + a user bubble.
    private static func fixture() -> [Message2] {
        let resolver = Message2Resolver()
        func resolve(_ dict: [String: Any]) -> Message2 { try! resolver.resolve(dict) }
        return [
            resolve([
                "type": "assistant", "uuid": UUID().uuidString, "session_id": "s",
                "message": [
                    "id": "m1", "type": "message", "role": "assistant",
                    "content": [
                        ["type": "text", "text": "Hello **world**\n\nSecond paragraph."]
                    ],
                ],
            ]),
            resolve([
                "type": "assistant", "uuid": UUID().uuidString, "session_id": "s",
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
                "message": ["role": "user", "content": "thanks!"],
            ]),
        ]
    }
}
