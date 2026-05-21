import AgentSDK
import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Visual review for `BackgroundTaskPopover`. Renders a single popover
/// with one running task (expanded card with live tail) and one
/// completed task (collapsed) so a reviewer can eyeball the Apple-style
/// grouping, status badges, and elapsed-time labels without launching
/// the app.
///
/// Opt-in (filename ends in `SnapshotTests`); see CLAUDE.md.
@MainActor
final class BackgroundTaskPopoverSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testRunningAndCompletedTasks() throws {
        let session = Self.makeSession(tasks: [
            ccterm.BackgroundTask(
                id: "btask_001",
                toolUseId: "toolu_001",
                description: "Run integration tests",
                taskType: "local_bash",
                command: "go test ./... -race -count=1",
                outputFile: nil,
                startedAt: Date().addingTimeInterval(-37),
                endedAt: nil,
                status: .running,
                summary: nil
            ),
            ccterm.BackgroundTask(
                id: "btask_000",
                toolUseId: "toolu_000",
                description: "Background sleep and echo task",
                taskType: "local_bash",
                command: "sleep 5 && echo done",
                outputFile: "/private/tmp/claude-501/sample/tasks/btask_000.output",
                startedAt: Date().addingTimeInterval(-180),
                endedAt: Date().addingTimeInterval(-175),
                status: .completed,
                summary: "Background command \"Background sleep and echo task\" completed (exit code 0)"
            ),
        ])

        let size = CGSize(width: 460, height: 420)
        let popover = BackgroundTaskPopover(session: session)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))

        let image = ViewSnapshot.render(popover, size: size, settle: 0.5)
        let url = ViewSnapshot.writePNG(image, name: "BackgroundTaskPopover")
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "BackgroundTaskPopover.png"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertGreaterThanOrEqual(image.size.width, size.width - 1)
    }

    // MARK: - Helpers

    private static func makeSession(tasks: [ccterm.BackgroundTask]) -> ccterm.Session {
        let runtime = SessionRuntime(
            sessionId: UUID().uuidString,
            repository: InMemorySessionRepository()
        )
        runtime.tasks = tasks
        return ccterm.Session(runtime: runtime)
    }
}
