import AppKit
import XCTest

@testable import ccterm

/// The jump bar of a command, a change, a new file and a read, wide and
/// narrow, in light and dark (design/transcript/02-command.md,
/// 03-file.md). Review only — `make test-unit FILTER=JumpBarViewSnapshotTests`,
/// then open `/tmp/ccterm-screenshots/JumpBarView.png`.
@MainActor
final class JumpBarViewSnapshotTests: XCTestCase {
    private let root = "/Users/me/dev/ccterm"

    private func header(_ content: DocumentContent) -> DocumentHeader {
        DocumentHeader(
            Document(
                reference: DocumentReference(transcriptURL: URL(fileURLWithPath: "/t.jsonl"), id: "c1"),
                content: content, workingDirectory: root))
    }

    private func controller(_ header: DocumentHeader, width: CGFloat) -> NSViewController {
        let bar = JumpBarView()
        bar.configure(with: header)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: JumpBarView.height))
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.heightAnchor.constraint(equalToConstant: JumpBarView.height),
        ])
        let controller = NSViewController()
        controller.view = container
        return controller
    }

    func testTheBarInEveryDocumentAndWidth() {
        let path = root + "/macos/TranscriptKit/Sources/TranscriptKit/TranscriptView.swift"
        let edit = ToolCallFixture.edit(
            path, old: "a", new: "b",
            hunks: [
                ToolCallFixture.hunk(oldStart: 1, oldLines: 1, newStart: 1, newLines: 2, lines: ["-a", "+b", "+c"])
            ])
        let waiting = ToolCallFixture.call(
            "Bash", #"{"command":"rm x","description":"Remove the cache"}"#, state: .waiting(reason: nil),
            hasResult: false)
        let headers: [(DocumentHeader, CGFloat)] = [
            (header(.command(ToolCallFixture.bash("make", description: "Run the unit tests"))), 640),
            (header(.command(ToolCallFixture.failedBash("make", description: "Run the unit tests", output: "x"))), 640),
            (header(.command(waiting)), 640),
            (header(.change([edit])), 640),
            (header(.change([edit])), 420),
            (header(.change([edit])), 300),
            (header(.newFile(ToolCallFixture.write(root + "/macos/ccterm/A.swift", content: "a\nb\nc"))), 640),
            (
                header(
                    .read(
                        ToolCallFixture.read(root + "/macos/ccterm/A.swift", content: "a\nb", startLine: 40, total: 880)
                    )),
                640
            ),
        ]
        let sheets = headers.map { header, width in
            ViewSnapshot.renderLightAndDark(
                { self.controller(header, width: width) }, size: CGSize(width: width, height: JumpBarView.height),
                name: "")
        }
        let url = ViewSnapshot.writeStack(sheets, name: "JumpBarView")
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTheButtonReportsToTheDelegate() {
        final class Recorder: JumpBarViewDelegate {
            var count = 0
            func jumpBarViewDidRequestShowInTranscript(_ jumpBar: JumpBarView) { count += 1 }
        }
        let bar = JumpBarView()
        let recorder = Recorder()
        bar.delegate = recorder
        bar.frame = NSRect(x: 0, y: 0, width: 400, height: JumpBarView.height)
        bar.configure(with: header(.command(ToolCallFixture.bash("ls"))))
        bar.layoutSubtreeIfNeeded()
        let button = bar.subviews.compactMap { $0 as? NSButton }.first
        button?.performClick(nil)
        XCTAssertEqual(recorder.count, 1)
    }
}
