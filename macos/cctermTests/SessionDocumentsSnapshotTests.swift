import AppKit
import DisplayModels
import XCTest

@testable import ccterm

/// The documents a session's own controls open — its log and its context —
/// under their jump bar, light and dark. Review only —
/// `make test-unit FILTER=SessionDocumentsSnapshotTests`, then open
/// `/tmp/ccterm-screenshots/SessionDocument-<name>.png`.
@MainActor
final class SessionDocumentsSnapshotTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/nonexistent/s.jsonl")
    private let size = CGSize(width: 720, height: 640)

    private func snapshot(_ name: String, _ document: Document) {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            defer { NSApp.appearance = nil }
            let controller = DocumentViewController(
                reference: document.reference, document: document, load: { _ in AsyncStream { $0.finish() } },
                makeConversation: { _, _ in NSViewController() }, showInTranscript: { _ in }, decide: { _, _ in })
            controller.loadView()
            controller.view.wantsLayer = true
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                controller.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            let image = ViewSnapshot.renderViewController(controller, size: size)
            let png = ViewSnapshot.writePNG(image, name: "SessionDocument-\(name)-\(suffix)")
            let attachment = XCTAttachment(contentsOfFile: png)
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testTheLog() {
        let log = """
            Error: Invalid API key · Please run /login
                at validateKey (cli.js:1204:11)
                at async init (cli.js:88:3)
            """
        snapshot(
            "log",
            SessionTabDocuments.log(
                SessionFailure(message: "Exit code 1 · Invalid API key", log: log), transcriptURL: url))
    }

    func testTheContext() {
        snapshot("context", SessionTabDocuments.context(ContextUsageFixture.sample, transcriptURL: url))
    }
}
