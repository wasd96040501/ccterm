import AgentSDK
import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Visual review for the two background-task surfaces: the compact
/// popover list (BackgroundTaskList) and the detail sheet
/// (BackgroundTaskDetailSheet) you reach by tapping a row. The list
/// is intentionally narrow + dense; the sheet is the surface that
/// shows the full command, output, and timestamps.
///
/// Opt-in (filename ends in `SnapshotTests`); see CLAUDE.md.
@MainActor
final class BackgroundTaskSheetSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Popover

    func testPopoverListRunningAndCompleted() throws {
        let session = Self.makeSession(tasks: Self.fixtureTasks())
        let size = CGSize(width: 360, height: 280)
        let view = BackgroundTaskList(session: session, onSelectTask: { _ in })
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))

        let image = ViewSnapshot.render(view, size: size, settle: 0.5)
        let url = ViewSnapshot.writePNG(image, name: "BackgroundTaskList")
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "BackgroundTaskList.png"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertGreaterThanOrEqual(image.size.width, size.width - 1)
    }

    // MARK: - Detail sheet — terminal task

    func testDetailSheetFailedTask() throws {
        let now = Date()
        let task = ccterm.BackgroundTask(
            id: "btask_failed",
            toolUseId: "toolu_failed",
            description: "Migration smoke (rolled back)",
            taskType: "local_bash",
            command: "make test-unit FILTER=MigrationSmoke",
            outputFile: nil,
            startedAt: now.addingTimeInterval(-720),
            endedAt: now.addingTimeInterval(-680),
            status: .failed,
            summary: "Background command \"Migration smoke\" failed (exit code 1)"
        )

        let size = CGSize(width: 640, height: 560)
        let view = BackgroundTaskDetailSheet(
            task: task,
            now: now,
            onStop: nil,
            onDismiss: {}
        )
        .frame(width: size.width, height: size.height)
        .background(Color(nsColor: .windowBackgroundColor))

        let image = ViewSnapshot.render(view, size: size, settle: 0.5)
        let url = ViewSnapshot.writePNG(image, name: "BackgroundTaskDetailSheet-failed")
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "BackgroundTaskDetailSheet-failed.png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Detail sheet — running task with stop button

    func testDetailSheetRunningTask() throws {
        let now = Date()
        let task = ccterm.BackgroundTask(
            id: "btask_running",
            toolUseId: "toolu_running",
            description: "Long-running tick generator (200 iterations)",
            taskType: "local_bash",
            command:
                "for i in $(seq 1 200); do echo \"tick $i\"; sleep 1; done",
            outputFile: nil,
            startedAt: now.addingTimeInterval(-92),
            endedAt: nil,
            status: .running,
            summary: nil
        )

        let size = CGSize(width: 640, height: 560)
        let view = BackgroundTaskDetailSheet(
            task: task,
            now: now,
            onStop: { _ in },
            onDismiss: {}
        )
        .frame(width: size.width, height: size.height)
        .background(Color(nsColor: .windowBackgroundColor))

        let image = ViewSnapshot.render(view, size: size, settle: 0.5)
        let url = ViewSnapshot.writePNG(image, name: "BackgroundTaskDetailSheet-running")
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "BackgroundTaskDetailSheet-running.png"
        attachment.lifetime = .keepAlways
        add(attachment)
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

    private static func fixtureTasks() -> [ccterm.BackgroundTask] {
        let now = Date()
        return [
            ccterm.BackgroundTask(
                id: "btask_001",
                toolUseId: "toolu_001",
                description: "Run integration tests",
                taskType: "local_bash",
                command: "go test ./... -race -count=1",
                outputFile: nil,
                startedAt: now.addingTimeInterval(-37),
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
                startedAt: now.addingTimeInterval(-180),
                endedAt: now.addingTimeInterval(-175),
                status: .completed,
                summary: "Background command \"Background sleep and echo task\" completed (exit code 0)"
            ),
            ccterm.BackgroundTask(
                id: "btask_002",
                toolUseId: "toolu_002",
                description: "Migration smoke (rolled back)",
                taskType: "local_bash",
                command: "make test-unit FILTER=MigrationSmoke",
                outputFile: nil,
                startedAt: now.addingTimeInterval(-720),
                endedAt: now.addingTimeInterval(-680),
                status: .failed,
                summary: "Background command \"Migration smoke\" failed (exit code 1)"
            ),
        ]
    }
}
