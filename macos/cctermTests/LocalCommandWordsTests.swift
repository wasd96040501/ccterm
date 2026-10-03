import DisplayModels
import XCTest

@testable import ccterm

/// Expected words are built from the same localized keys, so the tests hold
/// in any language the machine runs in.
final class LocalCommandWordsTests: XCTestCase {
    private func slash(
        _ name: String, _ arguments: String = "", output: String = "", error: String = ""
    )
        -> LocalCommand
    {
        LocalCommand(id: "l", command: .slash(name: name, arguments: arguments), output: output, errorOutput: error)
    }

    private func shell(_ line: String, output: String) -> LocalCommand {
        LocalCommand(id: "l", command: .shell(line), output: output, errorOutput: "")
    }

    func testASlashCommandIsItsNameAndArguments() {
        let command = slash("/model", "opus", output: "Set model to Opus")
        XCTAssertEqual(command.title, "/model")
        XCTAssertEqual(command.arguments, "opus")
        XCTAssertNil(command.fullName)
        XCTAssertEqual(command.inlineOutput, "Set model to Opus")
        XCTAssertFalse(command.isOutputCut)
        XCTAssertNil(command.lineCount)
    }

    func testASkillShowsItsShortNameAndTheWholeOneAsTheTooltip() {
        let command = slash("/skill-creator:skill-creator")
        XCTAssertEqual(command.title, "/skill-creator")
        XCTAssertEqual(command.fullName, "/skill-creator:skill-creator")
        XCTAssertNil(command.inlineOutput)
    }

    func testLongOutputShowsTwoLinesAndShowAll() {
        let command = slash("/context", output: "a\nb\nc\n")
        XCTAssertEqual(command.inlineOutput, "a\nb")
        XCTAssertTrue(command.isOutputCut)
    }

    func testOnlyErrorsShowAsErrors() {
        let command = slash("/x", error: "Unknown command")
        XCTAssertTrue(command.outputIsError)
        XCTAssertEqual(command.inlineOutput, "Unknown command")
    }

    func testAShellCommandSaysHowLongItsOutputWas() {
        let command = shell("git status", output: (1...12).map { "line \($0)" }.joined(separator: "\n"))
        XCTAssertEqual(command.title, "git status")
        XCTAssertEqual(command.lineCount, String(localized: "\(12) lines"))
        XCTAssertNil(command.inlineOutput)
        XCTAssertFalse(command.isOutputCut)
    }

    func testOneLineOfShellOutputFitsInline() {
        let command = shell("pwd", output: "/r\n")
        XCTAssertNil(command.lineCount)
        XCTAssertEqual(command.inlineOutput, "/r")
    }

    func testADividerSaysWhatChangedTheSession() {
        func label(_ kind: SessionDivider.Kind) -> String { SessionDivider(id: "d", kind: kind).label }
        XCTAssertEqual(
            label(.compacted(automatically: false, preTokens: 168_400, postTokens: 14_000)),
            String(localized: "Conversation compacted") + " · " + String(localized: "\("168k") → \("14k") tokens"))
        XCTAssertEqual(
            label(.compacted(automatically: true, preTokens: nil, postTokens: nil)),
            String(localized: "Compacted automatically"))
        XCTAssertEqual(label(.compacting), String(localized: "Compacting…"))
        XCTAssertTrue(label(.resumed(Date())).hasPrefix(String(localized: "Resumed · \("")")))
    }
}
