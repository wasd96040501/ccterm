import AgentSDK
import TranscriptKit
import XCTest

@testable import ccterm

/// What the reader said, ran and pasted, in the transcript: the bubble with
/// its tokens, the line under it, the thumbnails over it, and where a prompt
/// written here has got to (design/transcript/05-local.md, 08-live.md) — light
/// above dark. Review only — `make test-unit FILTER=PromptRowsSnapshotTests`,
/// then open `/tmp/ccterm-screenshots/PromptRows-*.png`.
@MainActor
final class PromptRowsSnapshotTests: XCTestCase {
    private func command(_ s: inout MessageScript, _ name: String, _ arguments: String, output: String? = nil) {
        s.user(
            "<command-name>\(name)</command-name><command-message>\(name)</command-message><command-args>\(arguments)</command-args>"
        )
        if let output { s.user("<local-command-stdout>\(output)</local-command-stdout>") }
    }

    func testCommands() {
        var s = MessageScript()
        command(&s, "/dataviz", "Pull the latest code; this PR is about designing live sessions")
        command(&s, "/model", "opus", output: "Set model to opus")
        command(&s, "/skill-creator:skill-creator", "make a skill for the whole team")
        command(&s, "/usage", "", output: "Plan: Max\nWeek: 41%\nToday: 7%\nReset: Tue")
        s.user("<bash-input>git status --short</bash-input>")
        s.user("<bash-stdout>M a\nM b\n?? c\nM d</bash-stdout><bash-stderr></bash-stderr>")
        s.user("<bash-input>pwd</bash-input>")
        s.user("<bash-stdout>/Users/me/repo</bash-stdout><bash-stderr></bash-stderr>")
        command(&s, "/login", "", output: nil)
        s.user("<local-command-stderr>Not logged in</local-command-stderr>")
        PageSnapshot.render(s.page, widths: [560, 340], height: 760, name: "PromptRows-commands", test: self)
    }

    func testDelivery() {
        var s = MessageScript()
        s.prompt("What does the build do?")
        s.reply("It compiles the app.")
        let local = [
            LocalPrompt(id: "1", text: "Then run the tests", delivery: .held),
            LocalPrompt(id: "2", text: "Also check the formatting", delivery: .queued),
            LocalPrompt(id: "3", text: "And push when green", delivery: .sent),
            LocalPrompt(id: "4", text: "/model opus", delivery: .held),
            LocalPrompt(id: "5", text: "Never arrived", delivery: .notSent(reason: "the session ended")),
        ]
        let page = TranscriptPage(
            Transcript(messages: s.messages), prompts: local,
            restarts: [SessionState.Restart(afterMessage: "a1", accountName: "Work", modelName: "Opus 4.5")])
        PageSnapshot.render(page, widths: [560, 340], height: 620, name: "PromptRows-delivery", test: self)
    }

    // MARK: - Against the design

    /// Each state of a prompt from Send (08-live.md *A prompt, from Send to the
    /// transcript*) beside the sheet's own, at its 301-pt column:
    /// `/tmp/ccterm-parity/<scheme>-part-<card>-pst0.png`. Captured as the
    /// screen composites it (its grey words are the design's), so it needs the
    /// display awake.
    func testDeliveryAgainstTheDesign() async throws {
        let summary = "Make the summary 12 pt and rebuild."
        let states: [(card: String, page: TranscriptPage)] = [
            ("18", local("Tidy the tab bar", .held)),
            ("19", local("Also update the docs", .queued)),
            ("20", local(summary, .sent)),
            ("21", confirmed(summary)),
            ("22", local(summary, .notSent(reason: "the session ended"))),
        ]
        for scheme in DesignParity.Scheme.allCases {
            for state in states {
                let id = "part-\(state.card)-pst0"
                let part = try DesignParity.part(id, scheme)
                let ours = try await column(state.page, part: part, scheme: scheme)
                attach(try DesignParity.write(id, scheme, ours: ours))
            }
        }
    }

    private func local(_ text: String, _ delivery: LocalPrompt.Delivery) -> TranscriptPage {
        TranscriptPage(
            Transcript(messages: []), prompts: [LocalPrompt(id: "p", text: text, delivery: delivery)], restarts: [])
    }

    private func confirmed(_ text: String) -> TranscriptPage {
        var s = MessageScript()
        s.prompt(text)
        return s.page
    }

    /// The page's rows in a column `part.width` wide, on the sheet's page, from
    /// the top of the first row down to the last's foot (or the part's height,
    /// whichever is more).
    private func column(
        _ page: TranscriptPage, part: DesignParity.Part, scheme: DesignParity.Scheme
    ) async throws
        -> NSImage
    {
        let margin: CGFloat = 20
        let host = PageSnapshot.Host(page: page, disclosure: .collapsed)
        host.loadView()
        // No inset over the first row: `rect(ofRow:)` is then where the row is in the view.
        host.transcript.contentInsets = NSEdgeInsets()
        host.view.layer?.backgroundColor = scheme.page.cgColor
        let window = CompositedCapture.mount(
            host, size: NSSize(width: part.width + 2 * margin, height: 240), appearance: scheme.appearance)
        defer {
            window.contentViewController = nil
            window.close()
        }
        let deadline = Date(timeIntervalSinceNow: 0.6)
        while Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
        host.view.layoutSubtreeIfNeeded()
        let count = host.transcript.numberOfRows
        let rows = (0..<count).map { host.transcript.rect(ofRow: $0) }.reduce(NSRect.null) { $0.union($1) }
        let image = try await CompositedCapture.pointImage(of: window)
        let height = max(part.height, ceil(rows.height))
        let crop = NSRect(x: margin, y: rows.minY, width: part.width, height: height)
        let out = NSImage(size: crop.size)
        out.lockFocus()
        // `rect(ofRow:)` measures y down; the image's y goes up.
        image.draw(
            in: NSRect(origin: .zero, size: crop.size),
            from: NSRect(x: crop.minX, y: image.size.height - crop.maxY, width: crop.width, height: crop.height),
            operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }

    private func attach(_ url: URL) {
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPictures() {
        var s = MessageScript()
        s.prompt(
            "Look at [Image #1] and compare it with [Image #2]",
            images: [ImageFixture.png(width: 640, height: 400), ImageFixture.png(width: 200, height: 300, hue: 0.05)],
            pasteIDs: [1, 2])
        s.prompt(
            "[Image #3]", images: [ImageFixture.png(width: 1000, height: 120, hue: 0.3)], pasteIDs: [3])
        s.prompt(
            "Here is [Image #4], and all the others",
            images: [
                ImageFixture.png(width: 640, height: 400), ImageFixture.png(width: 300, height: 300, hue: 0.1),
                ImageFixture.png(width: 640, height: 400, hue: 0.8), ImageFixture.png(width: 400, height: 500),
            ], pasteIDs: [4, 5, 6, 7])
        PageSnapshot.render(s.page, widths: [560, 340], height: 900, name: "PromptRows-pictures", test: self)
    }

    func testHoveringAPictureTokenOutlinesItsThumbnail() {
        var s = MessageScript()
        s.prompt(
            "Look at [Image #1] and [Image #2]",
            images: [ImageFixture.png(width: 640, height: 400), ImageFixture.png(width: 200, height: 300, hue: 0.05)],
            pasteIDs: [1, 2])
        let page = s.page
        PageSnapshot.render(page, widths: [560], height: 300, name: "PromptRows-hover", test: self) { host in
            host.highlightedImage = (page.entries[0].id, 2)
            host.transcript.reloadData()
        }
    }
}
