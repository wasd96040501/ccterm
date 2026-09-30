import XCTest

@testable import ccterm

/// The words of a command or file document: its header, its stat, the status
/// line of a command, the lines of a change (design/transcript/02-command.md,
/// 03-file.md). Expectations use the same localized keys, so they hold in any
/// language the machine runs in.
final class DocumentHeaderTests: XCTestCase {
    private let root = "/Users/me/dev/ccterm"

    private func header(_ content: DocumentContent) -> DocumentHeader {
        DocumentHeader(
            Document(
                reference: DocumentReference(transcriptURL: URL(fileURLWithPath: "/t.jsonl"), id: "c1"),
                content: content, workingDirectory: root))
    }

    // MARK: - Command

    func testACommandIsItsDescriptionAndTheTabCutsItTo32Characters() {
        let short = header(.command(ToolCallFixture.bash("make", description: "Run the unit tests")))
        XCTAssertEqual(short.title, "Run the unit tests")
        XCTAssertEqual(short.crumbs, ["Run the unit tests"])
        XCTAssertEqual(short.tile, Tile(glyph: .tool(.command), state: .done))

        let long = "Run the unit tests for the transcript view and its documents"
        let cut = header(.command(ToolCallFixture.bash("make", description: long)))
        XCTAssertEqual(cut.title.count, 32)
        XCTAssertTrue(cut.title.hasSuffix("…"))
        XCTAssertEqual(cut.crumbs, [long], "the jump bar shows it whole and cuts it by width")

        XCTAssertEqual(header(.command(ToolCallFixture.bash("ls"))).title, String(localized: "Command"))
    }

    func testABangCommandIsYouRan() {
        let local = LocalCommand(id: "l1", command: .shell("git status"), output: "", errorOutput: "")
        let header = header(.shellCommand(local))
        XCTAssertEqual(header.title, String(localized: "You ran"))
        XCTAssertEqual(header.tile, Tile(glyph: .tool(.command), state: .done))
        XCTAssertEqual(CommandSummary(local).status.string, String(localized: "Local"))
        XCTAssertEqual(CommandSummary(local).command, "git status")
    }

    func testTheTileFollowsTheCallsState() {
        let failed = ToolCallFixture.failedBash("make", output: "boom")
        XCTAssertEqual(header(.command(failed)).tile.state, .failed)
        let waiting = ToolCallFixture.call(
            "Bash", #"{"command":"rm -rf x"}"#, state: .waiting(reason: nil), hasResult: false)
        XCTAssertEqual(header(.command(waiting)).tile.state, .waiting)
    }

    func testAFailedCommandSaysFailedInRedWithItsExitCodeAndTime() {
        let summary = CommandSummary(
            ToolCallFixture.failedBash("make test", exit: 65, output: "error: nope\n** TEST FAILED **"))
        XCTAssertEqual(
            summary.status.string,
            String(localized: "Failed") + " · " + String(localized: "exit \(65)") + " · "
                + TimeInterval(48).durationText)
        XCTAssertEqual(summary.status.runs.first, .init(text: String(localized: "Failed"), style: .failure))
        XCTAssertEqual(summary.stdout, "error: nope\n** TEST FAILED **", "the exit line is the status, not output")
    }

    func testASuccessWritesOnlyTheTimeAndTheOneWarning() {
        let summary = CommandSummary(ToolCallFixture.bash("ls", stdout: "a\nb", sandboxOff: true, duration: 3))
        XCTAssertEqual(summary.status.string, TimeInterval(3).durationText)
        XCTAssertEqual(summary.warning, String(localized: "Sandbox off"))
        XCTAssertNil(CommandSummary(ToolCallFixture.bash("ls", stdout: "a")).warning)
        XCTAssertEqual(summary.stdout, "a\nb")
    }

    func testNoOutputAndTheCLIsNoteOnAnExitCode() {
        let none = CommandSummary(ToolCallFixture.bash("true"))
        XCTAssertEqual(none.emptyNote, String(localized: "No output"))
        let grep = CommandSummary(
            ToolCallFixture.bash("grep -rn x .", interpretation: "No matches found", duration: nil))
        XCTAssertEqual(grep.note, "No matches found")
    }

    /// The CLI runs a command with its stderr in stdout; what it records as
    /// stderr is its own note that it moved the shell back — in the real
    /// shape, after a newline. The note answers no question and isn't shown;
    /// anything else there is, without the blank line.
    func testStderrIsWhatTheCommandPrintedNotTheCLIsNote() {
        let note = "\nShell cwd was reset to /Users/me/dev/ccterm"
        let moved = CommandSummary(ToolCallFixture.bash("cd /tmp && ls", stdout: "a\nb", stderr: note))
        XCTAssertEqual(moved.stdout, "a\nb")
        XCTAssertEqual(moved.stderr, "", "the CLI's note is not the command's")

        let quiet = CommandSummary(ToolCallFixture.bash("cd /tmp && true", stderr: note))
        XCTAssertEqual(quiet.emptyNote, String(localized: "No output"), "the note is not output")

        let other = CommandSummary(ToolCallFixture.bash("x", stderr: "\nwarning: y" + note + "\n"))
        XCTAssertEqual(other.stderr, "warning: y")
    }

    func testALiveCommandSaysWhereItIs() {
        let running = ToolCallFixture.call("Bash", #"{"command":"sleep 9"}"#, state: .running, hasResult: false)
        let summary = CommandSummary(running)
        XCTAssertTrue(summary.isRunning)
        XCTAssertEqual(summary.emptyNote, String(localized: "Output appears when the command finishes."))
        XCTAssertEqual(summary.status.string, String(localized: "Running"))

        let denied = CommandSummary(
            ToolCallFixture.call("Bash", #"{"command":"rm x"}"#, state: .denied, hasResult: false))
        XCTAssertFalse(denied.hasOutputArea)
        XCTAssertEqual(denied.status.string, String(localized: "Denied"))
    }

    func testErrorLinesAreTheOnesThatSaySo() {
        XCTAssertTrue(CommandSummary.isErrorLine("A.swift:3:1: error: nope"))
        XCTAssertTrue(CommandSummary.isErrorLine("** TEST FAILED **"))
        XCTAssertTrue(CommandSummary.isErrorLine("make: *** [all] Error 2"))
        XCTAssertFalse(CommandSummary.isErrorLine("Test Suite started"))
    }

    // MARK: - Output

    func testAnsiBoldGreenAndRedAreRead() {
        let text = ANSIText(
            "plain \u{1B}[1;32mPASS\u{1B}[0m and \u{1B}[31mfail\u{1B}[0m\nnext \u{1B}[36mcyan\u{1B}[0m\n")
        XCTAssertEqual(text.lines.map(\.text), ["plain PASS and fail", "next cyan"])
        XCTAssertEqual(
            text.lines[0].spans,
            [LineSpan(range: 6..<10, style: .boldGreen), LineSpan(range: 15..<19, style: .red)])
        XCTAssertEqual(text.lines[1].spans, [])
    }

    func testAShellCommandsFirstWordIsTheCommandAndACdIsSetApart() {
        let split = ShellHighlighter.splitDirectoryChange("cd ~/dev/ccterm && make test-unit FILTER=A")
        XCTAssertEqual(split.prefix, "cd ~/dev/ccterm &&")
        XCTAssertEqual(split.rest, "make test-unit FILTER=A")
        XCTAssertEqual(ShellHighlighter.spans(in: split.rest), [LineSpan(range: 0..<4, style: .function)])
        XCTAssertNil(ShellHighlighter.splitDirectoryChange("ls -la").prefix)
    }

    // MARK: - Files

    func testACrumbTrailStartsAtTheSessionsDirectory() {
        XCTAssertEqual(
            DocumentHeader.crumbs(of: root + "/macos/TranscriptKit/A.swift", workingDirectory: root),
            ["ccterm", "macos", "TranscriptKit", "A.swift"])
        XCTAssertEqual(DocumentHeader.crumbs(of: "/etc/hosts", workingDirectory: root), ["etc", "hosts"])
    }

    func testAChangeSaysWhatWasAddedAndRemoved() {
        let edit = ToolCallFixture.edit(
            root + "/A.swift", old: "let a = 1", new: "let a = 2\nlet b = 3",
            hunks: [
                ToolCallFixture.hunk(
                    oldStart: 4, oldLines: 3, newStart: 4, newLines: 4,
                    lines: [" x", "-let a = 1", "+let a = 2", "+let b = 3", " y", " z"])
            ])
        let header = header(.change([edit]))
        XCTAssertEqual(header.title, "A.swift")
        XCTAssertEqual(header.crumbs, ["ccterm", "A.swift"])
        XCTAssertEqual(header.stat.string, "+2 −1")
        XCTAssertEqual(header.stat.runs.first, .init(text: "+2", style: .added))
        XCTAssertEqual(header.tile, Tile(glyph: .tool(.change), state: .done))
    }

    func testAChangeShowsItsHunksInPlaceWithFoldsBetweenThem() {
        let edit = ToolCallFixture.edit(
            "/r/A.swift", old: "a", new: "b",
            hunks: [
                ToolCallFixture.hunk(
                    oldStart: 2, oldLines: 2, newStart: 2, newLines: 2, lines: [" one", "-let a = 1", "+let a = 2"]),
                ToolCallFixture.hunk(oldStart: 40, oldLines: 1, newStart: 40, newLines: 1, lines: [" two"]),
            ])
        let lines = SourceLines.change([edit]).lines
        XCTAssertEqual(
            lines.map(\.kind), [.context, .removed, .added, .fold, .context])
        XCTAssertEqual(lines.map(\.number), [2, nil, 3, nil, 40], "removed lines have no number in the new file")
        XCTAssertEqual(lines[3].text, String(localized: "Lines \(4)–\(39)"))
        XCTAssertEqual(lines[1].changed, [8..<9], "the one character that differs")
        XCTAssertEqual(lines[2].changed, [8..<9])
    }

    func testWithTheOriginalFileTheLengthsAreCountedAtBothEnds() {
        let original = (1...20).map { "l\($0)" }.joined(separator: "\n")
        let edit = ToolCallFixture.edit(
            "/r/A.swift", old: "l10", new: "x",
            hunks: [
                ToolCallFixture.hunk(
                    oldStart: 9, oldLines: 3, newStart: 9, newLines: 3, lines: [" l9", "-l10", "+x", " l11"])
            ], originalFile: original)
        let lines = SourceLines.change([edit]).lines
        XCTAssertEqual(lines.first?.text, String(localized: "\(8) lines"))
        XCTAssertEqual(lines.last?.text, String(localized: "\(9) lines"))
    }

    func testAProposedEditHasNoNumbersAndAFailedOneSaysWhy() {
        let failed = ToolCallFixture.call(
            "Edit", #"{"file_path":"/r/A.swift","old_string":"a\nb","new_string":"c"}"#,
            state: .failed(message: "<tool_use_error>String to replace not found in file.</tool_use_error>"),
            isError: true)
        let lines = SourceLines.change([failed])
        XCTAssertEqual(lines.lines.map(\.kind), [.removed, .removed, .added])
        XCTAssertEqual(lines.lines.map(\.number), [nil, nil, nil])
        XCTAssertEqual(lines.notes, [.init(style: .error, text: "String to replace not found in file.")])
    }

    func testANewFileCountsItsLines() {
        let call = ToolCallFixture.write(root + "/n/B.swift", content: "a\nb\nc\n")
        let header = header(.newFile(call))
        XCTAssertEqual(header.stat.string, String(localized: "New · \(3) lines"))
        XCTAssertEqual(header.tile, Tile(glyph: .tool(.create), state: .done))
        XCTAssertEqual(SourceLines.newFile(call).lines.map(\.number), [1, 2, 3])
    }

    /// The row's meta and the document's stat are one count: a file's closing
    /// newline ends its last line, it doesn't start another.
    func testTheRowAndTheDocumentCountTheSameLines() {
        let writer = WorkLineWriter(workingDirectory: root)
        let created = ToolCallFixture.write(root + "/B.swift", content: "a\nb\nc\n")
        XCTAssertEqual(writer.line(for: [created], standalone: true).meta, header(.newFile(created)).stat)
        let proposed = ToolCallFixture.call(
            "Edit", #"{"file_path":"/r/A.swift","old_string":"a\nb\n","new_string":"c\n"}"#, state: .done,
            hasResult: false)
        XCTAssertEqual(header(.change([proposed])).stat.string, "+1 −2")
        XCTAssertEqual(writer.line(for: [proposed], standalone: true).meta, header(.change([proposed])).stat)
        let edited = ToolCallFixture.edit(
            root + "/A.swift", old: "let a = 1", new: "let a = 2\nlet b = 3",
            hunks: [
                ToolCallFixture.hunk(
                    oldStart: 4, oldLines: 3, newStart: 4, newLines: 4,
                    lines: [" x", "-let a = 1", "+let a = 2", "+let b = 3", " y", " z"])
            ])
        XCTAssertEqual(writer.line(for: [edited], standalone: true).meta, header(.change([edited])).stat)
    }

    func testAReadSaysWhichLinesOfHowMany() {
        let call = ToolCallFixture.read(root + "/C.swift", content: "a\nb\nc\n", startLine: 40, total: 880)
        let header = header(.read(call))
        XCTAssertEqual(header.stat.string, String(localized: "Lines \(40)–\(42) of \(880)"))
        XCTAssertEqual(SourceLines.read(call).lines.map(\.number), [40, 41, 42], "the file's own numbers")
        XCTAssertEqual(header.tile, Tile(glyph: .tool(.read), state: .done))
    }
}
