import AgentSDK
import AppKit
import Combine
import XCTest

@testable import ccterm

/// The whole window beside the design's playground scenes (design 08,
/// *Playground*), at its 1128 × 720: the title bar, the sidebar, the tab bar
/// and the editor, captured as the screen composites them. A library like the
/// scenes' — ccterm › Row gap and tool rows, ghostty › Tab bar accessory.
/// Review only — `TEST_LANGUAGE=en make test-unit FILTER=MainWindowSceneSnapshotTests`
/// after `make design-shots`, then `/tmp/ccterm-parity/<scheme>-scene-<name>.png`.
/// Needs the display awake.
@MainActor
final class MainWindowSceneSnapshotTests: XCTestCase {
    private typealias Rows = SessionDirectoryFixture
    private var fixture: SessionDirectoryFixture!

    override func setUpWithError() throws {
        fixture = try SessionDirectoryFixture()
        try fixture.write(
            "-dev-ccterm/rows.jsonl",
            [
                Rows.user(
                    "u0", cwd: "/dev/ccterm",
                    "The rows feel cramped in a narrow split. Make the gap between transcript rows configurable."),
                Rows.assistant(
                    "a0", parent: "u0",
                    "Done — `TranscriptView.rowSpacing` is public and defaults to 14; the tests pass."),
                Rows.customTitle("Row gap and tool rows"),
            ], modified: 200)
        try fixture.write(
            "-dev-ghostty/tabs.jsonl",
            [
                Rows.user("u0", cwd: "/dev/ghostty", "Add an accessory to the tab bar."),
                Rows.assistant("a0", parent: "u0", "Added."),
                Rows.customTitle("Tab bar accessory"),
            ], modified: 100)
    }

    override func tearDown() {
        fixture.remove()
    }

    func testTheScenes() async throws {
        for scheme in DesignParity.Scheme.allCases {
            for scene in ["empty", "new", "rest"] {
                let id = "scene-\(scene)"
                let part = try DesignParity.part(id, scheme)
                let library = LibraryStore(directories: Just(fixture.directory).eraseToAnyPublisher())
                library.start()
                defer { library.stop() }
                let controller = MainWindowController(library: library, context: .reading(), git: GitService())
                let window = try XCTUnwrap(controller.window)
                window.appearance = scheme.appearance
                window.setFrame(NSRect(x: 0, y: 0, width: part.width, height: part.height), display: false)
                defer { window.close() }
                window.orderFrontRegardless()
                try await settle(until: { !library.nodes.isEmpty })
                let split = try XCTUnwrap(window.contentViewController as? MainSplitViewController)
                switch scene {
                case "new":
                    split.newTab()
                case "rest":
                    let node = try XCTUnwrap(
                        library.nodes.flatMap(\.children).first { $0.title == "Row gap and tool rows" })
                    let sidebar = try XCTUnwrap(split.splitViewItems[0].viewController as? SidebarViewController)
                    split.sidebarViewController(sidebar, didOpen: node)
                default:
                    break
                }
                try await settle(seconds: 1)
                let image = try await CompositedCapture.pointImage(of: window)
                let url = try DesignParity.write(id, scheme, ours: image)
                let attachment = XCTAttachment(contentsOfFile: url)
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    private func settle(seconds: TimeInterval) async throws {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    private func settle(until condition: () -> Bool) async throws {
        let deadline = Date(timeIntervalSinceNow: 10)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "the library never read")
    }
}
