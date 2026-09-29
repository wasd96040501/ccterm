import AppKit
import XCTest

@testable import ccterm

/// A words document, light and dark: an agent's report and the task list, as
/// `DocumentMarkdown` words them. Review only —
/// `make test-unit FILTER=MarkdownDocumentViewControllerSnapshotTests`, then
/// open `/tmp/ccterm-screenshots/MarkdownDocumentViewController-*.png`.
@MainActor
final class MarkdownDocumentViewControllerSnapshotTests: XCTestCase {
    private func render(_ markdown: String, name: String) {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let controller = MarkdownDocumentViewController(markdown: markdown)
            controller.loadView()
            NSApp.appearance = NSAppearance(named: appearance)
            defer { NSApp.appearance = nil }
            controller.view.wantsLayer = true
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                controller.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            let size = CGSize(width: 720, height: 420)
            let image = ViewSnapshot.renderViewController(controller, size: size)
            let url = ViewSnapshot.writePNG(image, name: "MarkdownDocumentViewController-\(name)-\(suffix)")
            let attachment = XCTAttachment(contentsOfFile: url)
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertEqual(image.size, size)
        }
    }

    func testAnAgentsReport() {
        var s = MessageScript()
        s.call("a", "Agent", #"{"description":"Find hard-coded row gaps","prompt":"p","subagent_type":"Explore"}"#)
        s.result(
            "a",
            output:
                #"{"status":"completed","agentId":"a1","content":[{"type":"text","text":"Found three call sites of `rowSpacing`:\n\n- `TranscriptView.swift:324` — the declaration\n- `TranscriptView.swift:332` — `intercellSpacing`\n- `TranscriptViewTests.swift:88` — the test\n\nAnd one hard-coded 14 in `EditorAreaTests.swift:118`."}],"totalToolUseCount":9,"totalDurationMs":71000,"totalTokens":5}"#
        )
        let page = s.page
        render(DocumentMarkdown.markdown(for: page.document(for: "a")!), name: "agent")
    }

    func testTheTaskList() {
        var s = MessageScript()
        s.call(
            "t", "TodoWrite",
            #"{"todos":[{"content":"Read how rows are spaced","status":"completed","activeForm":"a"},{"content":"Make rowSpacing public","status":"completed","activeForm":"a"},{"content":"Update the test","status":"in_progress","activeForm":"a"},{"content":"Build the demo","status":"pending","activeForm":"a"}]}"#
        )
        s.result("t")
        render(DocumentMarkdown.markdown(for: s.page.document(for: "t")!), name: "tasks")
    }
}
