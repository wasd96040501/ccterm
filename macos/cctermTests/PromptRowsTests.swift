import AgentSDK
import XCTest

@testable import ccterm

/// What the user said, ran or pasted, as the page words it and the rows split
/// it (design/transcript/05-local.md, 08-live.md *A prompt, from Send to the
/// transcript*): a command is the user's bubble with a token and a line under
/// it; a prompt written here is drawn from Send, dimmed while it waits, with its
/// delivery under it; pictures are thumbnails over the bubble.
@MainActor
final class PromptRowsTests: XCTestCase {

    // MARK: - Commands

    func testASlashCommandIsABubbleWithItsNameAsAToken() {
        let bubble = Bubble.slash(name: "/model", arguments: "opus")
        XCTAssertEqual(bubble.text, "/model opus")
        XCTAssertEqual(bubble.tokens, [Bubble.Token(range: 0..<6, kind: .command, toolTip: nil)])
        XCTAssertFalse(bubble.isPending)
    }

    func testACommandWithoutArgumentsIsOnlyItsToken() {
        let bubble = Bubble.slash(name: "/usage", arguments: "")
        XCTAssertEqual(bubble.text, "/usage")
        XCTAssertEqual(bubble.tokens.first?.range, 0..<6)
    }

    func testASkillShowsItsShortNameAndTheFullOneIsTheToolTip() {
        let bubble = Bubble.slash(name: "/skill-creator:skill-creator", arguments: "make one")
        XCTAssertEqual(bubble.text, "/skill-creator make one")
        XCTAssertEqual(
            bubble.tokens,
            [Bubble.Token(range: 0..<14, kind: .command, toolTip: "/skill-creator:skill-creator")])
    }

    func testAShellCommandIsMonospacedWithABangToken() {
        let bubble = Bubble.shell("git status --short")
        XCTAssertEqual(bubble.text, "! git status --short")
        XCTAssertEqual(bubble.tokens, [Bubble.Token(range: 0..<1, kind: .command, toolTip: nil)])
        XCTAssertTrue(bubble.isMonospaced)
    }

    func testACommandsRowsAreItsBubbleAndItsOutputLine() {
        var s = MessageScript()
        s.user(
            "<command-name>/model</command-name><command-message>model</command-message><command-args>opus</command-args>"
        )
        s.user("<local-command-stdout>Set model to opus</local-command-stdout>")
        let rows = PageRow.rows(for: s.page)
        XCTAssertEqual(rows.map(\.id.part), [.main, .note])
        XCTAssertEqual(rows[0].kind, .prompt(Bubble.slash(name: "/model", arguments: "opus")))
        XCTAssertEqual(rows[1].kind, .note(Note(text: "Set model to opus")))
    }

    func testACommandThatPrintedNothingHasNoLine() {
        let silent = LocalCommand(id: "c", command: .slash(name: "/x", arguments: ""), output: "", errorOutput: "")
        let rows = PageRow.rows(for: TranscriptPage(entries: [.command(silent)]))
        XCTAssertEqual(rows.map(\.id.part), [.main])
    }

    /// `/context` prints its total, then a blank line: the note is the total
    /// alone, so *· Show all* follows it on the same line.
    func testABlankSecondLineIsNoLineToShow() {
        let command = LocalCommand(
            id: "c", command: .slash(name: "/context", arguments: ""),
            output: "18k / 200k tokens\n\nSystem 3k\nTools 9k",
            errorOutput: "")
        XCTAssertEqual(command.note?.text, "18k / 200k tokens")
        XCTAssertEqual(command.note?.link?.isAfterDot, true)
        let indented = LocalCommand(
            id: "c", command: .slash(name: "/x", arguments: ""), output: "  total\n  part", errorOutput: "")
        XCTAssertEqual(indented.note?.text, "  total\n  part", "only blank lines go, never a line's own spaces")
    }

    func testALongSlashOutputIsCutWithShowAllBelow() {
        let command = LocalCommand(
            id: "c", command: .slash(name: "/usage", arguments: ""), output: "a\nb\nc\nd", errorOutput: "")
        XCTAssertEqual(command.note?.text, "a\nb")
        XCTAssertEqual(
            command.note?.link, Note.Link(title: String(localized: "Show all"), intent: .open("c"), isAfterDot: true))
    }

    func testAShellCommandsOutputIsItsLengthAsALink() {
        let command = LocalCommand(
            id: "c", command: .shell("git status"), output: "one\ntwo\nthree\nfour\n", errorOutput: "")
        XCTAssertEqual(
            command.note,
            Note(text: "", link: Note.Link(title: String(localized: "\(4) lines") + " ›", intent: .open("c"))))
        let one = LocalCommand(id: "d", command: .shell("pwd"), output: "/r\n", errorOutput: "")
        XCTAssertEqual(one.note, Note(text: "/r"))
    }

    func testStderrIsAFailureLine() {
        let command = LocalCommand(
            id: "c", command: .slash(name: "/login", arguments: ""), output: "", errorOutput: "Not logged in")
        XCTAssertEqual(command.note, Note(text: "Not logged in", style: .failure))
    }

    // MARK: - Prompts written here

    private func prompt(_ text: String, _ delivery: LocalPrompt.Delivery?) -> PromptEntry {
        PromptEntry(id: "u1", text: text, images: [], delivery: delivery)
    }

    func testAHeldPromptIsDimmedWithItsWordsUnderIt() {
        let held = prompt("Hello", .held)
        XCTAssertEqual(held.bubble?.isPending, true)
        XCTAssertEqual(held.note, Note(text: String(localized: "Sent when Claude is ready")))
    }

    func testAQueuedPromptCanBeWithdrawn() {
        let queued = prompt("Hello", .queued)
        XCTAssertEqual(queued.bubble?.isPending, true)
        XCTAssertEqual(
            queued.note,
            Note(
                text: String(localized: "Queued"),
                link: Note.Link(title: String(localized: "Withdraw"), intent: .withdraw("u1"))))
    }

    func testASentPromptIsJustABubble() {
        let sent = prompt("Hello", .sent)
        XCTAssertEqual(sent.bubble?.isPending, false)
        XCTAssertNil(sent.note)
    }

    func testAnUnsentPromptSaysWhyAndCanBeResent() {
        let unsent = prompt("Hello", .notSent(reason: "the session ended"))
        XCTAssertEqual(unsent.bubble?.isPending, false)
        XCTAssertEqual(
            unsent.note,
            Note(
                text: String(localized: "Not sent — \("the session ended")"), style: .notSent,
                link: Note.Link(title: String(localized: "Resend"), intent: .resend("u1"))))
        XCTAssertEqual(prompt("x", .notSent(reason: "")).note?.text, String(localized: "Not sent"))
    }

    func testAPromptFromTheTranscriptHasNoDeliveryAndNoDimming() {
        let own = prompt("Hello", nil)
        XCTAssertEqual(own.bubble?.isPending, false)
        XCTAssertNil(own.note)
    }

    func testATypedCommandIsATokenInAPromptWrittenHere() {
        let local = prompt("/model opus", .held)
        XCTAssertEqual(local.bubble?.tokens, [Bubble.Token(range: 0..<6, kind: .command, toolTip: nil)])
        // The transcript's own prompt reads no command out of its words.
        XCTAssertEqual(prompt("/model opus", nil).bubble?.tokens, [])
        // A path is not a command.
        XCTAssertEqual(prompt("/ is the root", .held).bubble?.tokens, [])
    }

    func testAPromptWrittenHereIsDrawnAtTheEndUnderItsUUID() {
        var s = MessageScript()
        s.prompt("Hi")
        s.reply("Hello")
        let transcript = Transcript(messages: s.messages)
        let local = [LocalPrompt(id: "u-new", text: "More", delivery: .held)]
        let page = TranscriptPage(transcript, prompts: local)
        XCTAssertEqual(page.entries.last?.id, "u-new")
        guard case .prompt(let prompt)? = page.entries.last else { return XCTFail("\(page.entries)") }
        XCTAssertEqual(prompt.delivery, .held)
        XCTAssertEqual(PageRow.rows(for: page).suffix(2).map(\.id.part), [.main, .note])
    }

    /// The replay arrives with the same uuid: the transcript's message is the
    /// bubble, in the same rows, and the delivery under it is gone.
    func testTheReplayConfirmsAPromptInPlace() {
        let local = [LocalPrompt(id: "u-new", text: "More", delivery: .sent)]
        var s = MessageScript()
        s.prompt("Hi")
        s.reply("Hello")
        let before = TranscriptPage(Transcript(messages: s.messages), prompts: local)
        s.user("More", uuid: "u-new")
        let after = TranscriptPage(Transcript(messages: s.messages), prompts: local)

        XCTAssertEqual(before.entries.filter { $0.id == "u-new" }.count, 1)
        XCTAssertEqual(after.entries.filter { $0.id == "u-new" }.count, 1, "kept once, by uuid")
        let was = PageRow.rows(for: before).first { $0.id.entry == "u-new" }
        let now = PageRow.rows(for: after).first { $0.id.entry == "u-new" }
        XCTAssertEqual(was?.id, now?.id, "the same row, so TranscriptKit keeps it and nothing flashes")
        XCTAssertEqual(was?.kind, now?.kind)
    }

    func testAQueuedPromptTheCLIFoldedMidTurnMovesToWhereItWasPut() {
        var s = MessageScript()
        s.prompt("Hi")
        s.call("c1", "Bash", #"{"command":"make"}"#)
        let local = [LocalPrompt(id: "q", text: "Also this", delivery: .queued)]
        let queued = PageRow.rows(for: TranscriptPage(Transcript(messages: s.messages), prompts: local))
        XCTAssertEqual(queued.last?.id.entry, "q")

        s.result("c1")
        s.user("Also this", uuid: "q")
        s.reply("Done")
        let folded = PageRow.rows(for: TranscriptPage(Transcript(messages: s.messages), prompts: local))
        XCTAssertEqual(folded.compactMap { $0.id.entry == "q" ? $0.id.part : nil }, [.main])
        XCTAssertNotEqual(folded.last?.id.entry, "q", "no longer at the end")

        let changes = PageRow.changes(from: queued, to: folded)
        XCTAssertFalse(changes.isEmpty)
    }

    func testAPromptHandedBackToTheFieldIsNotDrawn() {
        let local = [LocalPrompt(id: "u", text: "Words", delivery: .returned)]
        let page = TranscriptPage(Transcript(messages: []), prompts: local)
        XCTAssertTrue(page.entries.isEmpty)
    }

    // MARK: - Restarts

    func testARestartIsADividerAfterTheMessageThatWasLast() {
        var s = MessageScript()
        s.prompt("Hi")
        s.reply("Hello", uuid: "last")
        s.prompt("Again")
        let restart = SessionState.Restart(afterMessage: "last", accountName: "Work", modelName: "Opus 4.5")
        let page = TranscriptPage(Transcript(messages: s.messages), restarts: [restart])

        XCTAssertEqual(page.entries.count, 4)
        guard case .divider(let divider) = page.entries[2] else { return XCTFail("\(page.entries)") }
        XCTAssertEqual(divider.kind, .restarted(account: "Work", model: "Opus 4.5"))
        XCTAssertEqual(divider.label, String(localized: "Restarted as \("Work") · \("Opus 4.5")"))
        XCTAssertNil(divider.linkTitle)
    }

    func testARestartWithNoMessageIsTheFirstRow() {
        var s = MessageScript()
        s.prompt("Hi")
        let restart = SessionState.Restart(afterMessage: nil, accountName: "Work", modelName: "Opus")
        let page = TranscriptPage(Transcript(messages: s.messages), restarts: [restart])
        guard case .divider? = page.entries.first else { return XCTFail("\(page.entries)") }
    }

    func testARestartWhoseMessageIsGoneGoesAtTheEnd() {
        var s = MessageScript()
        s.prompt("Hi")
        let restart = SessionState.Restart(afterMessage: "missing", accountName: "Work", modelName: "Opus")
        let page = TranscriptPage(Transcript(messages: s.messages), restarts: [restart])
        guard case .divider? = page.entries.last else { return XCTFail("\(page.entries)") }
    }

    // MARK: - Pictures

    func testAPastedPictureIsAThumbnailAboveTheBubbleAndATokenInIt() throws {
        var s = MessageScript()
        s.prompt(
            "Look at [Image #2] please", images: [ImageFixture.png(width: 300, height: 200)], pasteIDs: [2])
        let page = s.page
        guard case .prompt(let prompt) = page.entries[0] else { return XCTFail("\(page.entries)") }
        let image = try XCTUnwrap(prompt.images.first)
        XCTAssertEqual(image.number, 2)
        XCTAssertEqual(image.dimensions, "300 × 200")
        XCTAssertEqual(image.format, "PNG")
        XCTAssertEqual(image.title, String(localized: "Image \(2)"))

        let name = String(localized: "Image \(2)")
        XCTAssertEqual(prompt.bubble?.text, "Look at \(name) please")
        XCTAssertEqual(
            prompt.bubble?.tokens, [Bubble.Token(range: 8..<(8 + name.utf16.count), kind: .image(number: 2))])

        let rows = PageRow.rows(for: page)
        XCTAssertEqual(rows.map(\.id.part), [.attachments, .main])
        XCTAssertEqual(page.document(for: image.id), .image(image))
        XCTAssertEqual(page.entryIndex(containing: image.id), 0)
    }

    func testPicturesAreNumberedByTheCLIsCounterOrByPosition() {
        var s = MessageScript()
        let png = ImageFixture.png(width: 20, height: 20)
        s.prompt("[Image #3] [Image #5]", images: [png, png], pasteIDs: [3, 5])
        s.prompt("[Image #1]", images: [png], pasteIDs: [])
        guard case .prompt(let first) = s.page.entries[0], case .prompt(let second) = s.page.entries[1] else {
            return XCTFail("\(s.page.entries)")
        }
        XCTAssertEqual(first.images.map(\.number), [3, 5])
        XCTAssertEqual(second.images.map(\.number), [1])
    }

    func testPicturesWithNoWordsAreThumbnailsAlone() {
        var s = MessageScript()
        s.prompt("[Image #1]", images: [ImageFixture.png(width: 20, height: 20)], pasteIDs: [1])
        XCTAssertEqual(PageRow.rows(for: s.page).map(\.id.part), [.attachments])
    }

    func testATokenWithNoPictureBehindItStaysWords() {
        var s = MessageScript()
        s.prompt("See [Image #9]")
        guard case .prompt(let prompt) = s.page.entries[0] else { return XCTFail() }
        XCTAssertEqual(prompt.bubble?.text, "See [Image #9]")
        XCTAssertEqual(prompt.bubble?.tokens, [])
    }

    func testThePictureTokensLinkNamesItsNumber() {
        let url = Bubble.imageURL(3)
        XCTAssertEqual(Bubble.imageNumber(of: url), 3)
        XCTAssertNil(Bubble.imageNumber(of: URL(string: "https://example.com")!))
    }

    func testTheThumbnailsLayoutWrapsWithinTheBubblesShareAndRightAligns() throws {
        let wide = try XCTUnwrap(PromptImage(ImageFixture.png(width: 400, height: 200), number: 1, entryID: "p"))
        let frames = AttachmentsRowView.frames(for: [wide, wide, wide], width: 520)
        // 192 wide each, 4 apart: two fit in 75 % of 520 (390), the third wraps.
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames[0].height, 96)
        XCTAssertEqual(frames[0].width, 192)
        XCTAssertEqual(frames[1].maxX, 520, "right-aligned with the bubble")
        XCTAssertEqual(frames[1].minX - frames[0].maxX, 4)
        XCTAssertEqual(frames[2].minY, 100, "wrapped under the first, 4 apart")
        XCTAssertEqual(frames[2].maxX, 520)
        XCTAssertEqual(
            AttachmentsRowView.height(for: .init(images: [wide, wide, wide], highlighted: nil), width: 520), 196)
    }

    func testASpacingKeepsAThumbnailRowCloseOverItsBubble() {
        var s = MessageScript()
        s.prompt("Look", images: [ImageFixture.png(width: 20, height: 20)], pasteIDs: [1])
        let rows = PageRow.rows(for: s.page)
        XCTAssertEqual(rows[1].spacingAbove(after: rows[0]), 4)
        s.user(
            "<command-name>/model</command-name><command-message>m</command-message><command-args>opus</command-args>"
        )
        s.user("<local-command-stdout>Set</local-command-stdout>")
        let command = PageRow.rows(for: s.page).suffix(2)
        XCTAssertEqual(command.last?.spacingAbove(after: command.first), 3)
    }
}
