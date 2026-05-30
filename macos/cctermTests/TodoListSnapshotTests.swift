import AgentSDK
import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Visual review for the todo popover. Opt-in (filename ends in
/// `SnapshotTests`); see CLAUDE.md.
@MainActor
final class TodoListSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPopoverActiveAndCompleted() throws {
        let session = Self.makeSession(todos: Self.fixtureTodos())
        let size = CGSize(width: 340, height: 360)
        let view = TodoList(session: session)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))

        let image = ViewSnapshot.render(view, size: size, settle: 0.5)
        let url = ViewSnapshot.writePNG(image, name: "TodoList")
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "TodoList.png"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertGreaterThanOrEqual(image.size.width, size.width - 1)
    }

    func testPopoverAllCompleted() throws {
        let todos = Self.fixtureTodos().map { entry -> TodoEntry in
            TodoEntry(
                id: entry.id,
                subject: entry.subject,
                description: entry.description,
                activeForm: entry.activeForm,
                status: .completed,
                createdAt: entry.createdAt,
                updatedAt: entry.updatedAt
            )
        }
        let session = Self.makeSession(todos: todos)
        let size = CGSize(width: 340, height: 360)
        let view = TodoList(session: session)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))

        let image = ViewSnapshot.render(view, size: size, settle: 0.5)
        let url = ViewSnapshot.writePNG(image, name: "TodoList-all-done")
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "TodoList-all-done.png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Helpers

    private static func makeSession(todos: [TodoEntry]) -> ccterm.Session {
        let runtime = SessionRuntime(
            sessionId: UUID().uuidString,
            repository: InMemorySessionRepository()
        )
        runtime.todos = todos
        return ccterm.Session(runtime: runtime)
    }

    private static func fixtureTodos() -> [TodoEntry] {
        let now = Date()
        return [
            TodoEntry(
                id: "1",
                subject: "Read the existing transcript renderer doc",
                description:
                    "Skim NativeTranscript2/CLAUDE.md to understand the diff path before editing.",
                activeForm: nil,
                status: .completed,
                createdAt: now.addingTimeInterval(-720),
                updatedAt: now.addingTimeInterval(-650)
            ),
            TodoEntry(
                id: "2",
                subject: "Sketch the memo-style todo popover",
                description:
                    "Leading status circle, grouped Active / Done sections, completed rows dimmed.",
                activeForm: "Drafting the todo popover layout",
                status: .inProgress,
                createdAt: now.addingTimeInterval(-480),
                updatedAt: now.addingTimeInterval(-120)
            ),
            TodoEntry(
                id: "3",
                subject: "Wire the chrome button visibility rules",
                description: "Hidden when no todos; stays mounted once any row exists.",
                activeForm: nil,
                status: .pending,
                createdAt: now.addingTimeInterval(-360),
                updatedAt: now.addingTimeInterval(-360)
            ),
            TodoEntry(
                id: "4",
                subject: "Add a snapshot test for the popover",
                description: nil,
                activeForm: nil,
                status: .pending,
                createdAt: now.addingTimeInterval(-300),
                updatedAt: now.addingTimeInterval(-300)
            ),
        ]
    }
}
