import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// A document's body is laid out once, at the width it shows at: it arrives
/// into a shell already sized, so nothing in it is measured at zero or at a
/// passing width and then again — which would draw a frame of the wrong wrap
/// before the right one. Records every width the body's root, each scroll
/// view's document view and each text view take, for each body kind, whether the document came
/// with the click or the shell loaded it (a tab made from history).
@MainActor
final class DocumentMountTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/nonexistent/d.jsonl")
    private var stage: AppKitStage?
    private var observer: NSObjectProtocol?

    override func tearDown() async throws {
        unmount()
    }

    func testACommandBodyIsLaidOutOnlyAtItsWidth() async throws {
        try await assertLaidOutOnce("c1", handedIn: true)
        try await assertLaidOutOnce("c1", handedIn: false)
    }

    func testAChangeBodyIsLaidOutOnlyAtItsWidth() async throws {
        try await assertLaidOutOnce("c2", handedIn: true)
        try await assertLaidOutOnce("c2", handedIn: false)
    }

    func testAMarkdownBodyIsLaidOutOnlyAtItsWidth() async throws {
        try await assertLaidOutOnce("c3", handedIn: true)
        try await assertLaidOutOnce("c3", handedIn: false)
    }

    // MARK: - Helpers

    /// Every width each view under the shell took, in order.
    private final class Widths: @unchecked Sendable {
        var seen: [ObjectIdentifier: [CGFloat]] = [:]
    }

    /// A command with a long output, an edit and a task list.
    private func transcript() -> Transcript {
        var script = MessageScript()
        script.reply("Working on it.")
        script.call("c1", "Bash", #"{"command":"make test","description":"Run the tests"}"#)
        script.result(
            "c1",
            (1...80).map { "line \($0) of the output, long enough to wrap at a narrow width" }.joined(separator: "\n"))
        script.call("c2", "Edit", #"{"file_path":"/r/A.swift","old_string":"let a = 1","new_string":"let a = 2"}"#)
        script.result(
            "c2",
            output: ToolCallFixture.json([
                "filePath": "/r/A.swift", "oldString": "let a = 1", "newString": "let a = 2",
                "structuredPatch": [
                    ToolCallFixture.hunk(
                        oldStart: 4, oldLines: 3, newStart: 4, newLines: 3,
                        lines: [" x", "-let a = 1", "+let a = 2", " y"])
                ],
            ]))
        script.call(
            "c3", "TodoWrite",
            #"{"todos":[{"content":"Read the design","status":"completed","activeForm":"Reading"},{"content":"Build the rows","status":"in_progress","activeForm":"Building"}]}"#
        )
        script.result("c3")
        var file = Transcript(data: Data())
        file.messages = script.messages
        return file
    }

    private func assertLaidOutOnce(
        _ id: String, handedIn: Bool, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        unmount()
        let transcript = transcript()
        let reference = DocumentReference(transcriptURL: url, id: id)
        let shell = DocumentViewController(
            reference: reference, document: handedIn ? TranscriptPage(transcript).document(reference) : nil,
            loadTranscript: { _ in transcript }, makeConversation: { _, _ in NSViewController() })
        let widths = Widths()
        let root = shell.view
        observer = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: nil, queue: nil
        ) { note in
            MainActor.assumeIsolated {
                guard let view = note.object as? NSView, view.frame.width > 0, view.isDescendant(of: root) else {
                    return
                }
                // A table is laid out when it has rows to lay out; its width
                // before then measures nothing.
                if let table = view as? NSTableView, table.numberOfRows == 0 { return }
                widths.seen[ObjectIdentifier(view), default: []].append(view.frame.width)
            }
        }
        stage = AppKitStage.mount(shell, size: CGSize(width: 640, height: 600))
        await stage?.settle()
        let path = "\(id), \(handedIn ? "handed in" : "loaded")"
        let body = try XCTUnwrap(shell.children.first, "no body for \(path)", file: file, line: line)
        let scrolled = stage?.findAll(NSScrollView.self, in: body.view).compactMap(\.documentView) ?? []
        XCTAssertFalse(scrolled.isEmpty, "premise: \(path)'s body scrolls", file: file, line: line)
        let texts: [NSView] = stage?.findAll(NSTextView.self, in: body.view) ?? []
        for view in [body.view] + scrolled + texts {
            let others = (widths.seen[ObjectIdentifier(view)] ?? []).filter { abs($0 - view.frame.width) > 0.5 }
            XCTAssertEqual(
                others, [], "\(path): \(type(of: view)) was laid out at \(others) before \(view.frame.width)",
                file: file, line: line)
        }
    }

    private func unmount() {
        observer.map(NotificationCenter.default.removeObserver)
        observer = nil
        stage?.teardown()
        stage = nil
    }
}
