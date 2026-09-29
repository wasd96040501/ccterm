import XCTest

@testable import AgentSDK

final class LaunchLineTests: XCTestCase {
    private func parse(_ line: String) throws -> LaunchLine { try XCTUnwrap(LaunchLine(line)) }

    private func pairs(_ line: LaunchLine) -> [[String]] { line.variables.map { [$0.name, $0.value] } }

    func testEmptyAndWhitespaceAreNil() {
        XCTAssertNil(LaunchLine(""))
        XCTAssertNil(LaunchLine("  \t\n "))
    }

    func testPrefixAssignmentsCommandAndArguments() throws {
        let line = try parse("A=1 B=two claude --model opus  ")
        XCTAssertEqual(pairs(line), [["A", "1"], ["B", "two"]])
        XCTAssertEqual(line.command, "claude")
        XCTAssertEqual(line.arguments, "--model opus")
    }

    func testCommandWithoutArguments() throws {
        let line = try parse("claude")
        XCTAssertEqual(line.command, "claude")
        XCTAssertNil(line.arguments)
        XCTAssertTrue(line.variables.isEmpty)
    }

    func testAliasBodyKeepsQuotedArgumentsRaw() throws {
        let line = try parse(#"ANTHROPIC_BASE_URL="https://x.test/v1" claude --append-system-prompt "be terse""#)
        XCTAssertEqual(pairs(line), [["ANTHROPIC_BASE_URL", "https://x.test/v1"]])
        XCTAssertEqual(line.command, "claude")
        XCTAssertEqual(line.arguments, #"--append-system-prompt "be terse""#)
    }

    func testExportLinesHaveNoCommand() throws {
        let line = try parse("export A='x y' B=\"z\" C=bare")
        XCTAssertEqual(pairs(line), [["A", "x y"], ["B", "z"], ["C", "bare"]])
        XCTAssertNil(line.command)
        XCTAssertNil(line.arguments)
    }

    func testQuoteForms() throws {
        let line = try parse(#"A="a \"q\" $b" B='it\' C=x"y z"w D=a\ b claude"#)
        XCTAssertEqual(pairs(line), [["A", #"a "q" $b"#], ["B", #"it\"#], ["C", "xy zw"], ["D", "a b"]])
    }

    func testEnvWordFollowedByAssignments() throws {
        let line = try parse("A=1 env B=2 claude -p")
        XCTAssertEqual(pairs(line), [["A", "1"], ["B", "2"]])
        XCTAssertEqual(line.command, "claude")
        XCTAssertEqual(line.arguments, "-p")
    }

    func testExportThenEnv() throws {
        let line = try parse("export A=1 env B=2")
        XCTAssertEqual(pairs(line), [["A", "1"], ["B", "2"]])
        XCTAssertNil(line.command)
    }

    func testTildeExpandsAtValueStartOnly() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let line = try parse("A=~/cfg B=~ C=x~/y D='~/q' claude ~/arg")
        XCTAssertEqual(pairs(line), [["A", home + "/cfg"], ["B", "~"], ["C", "x~/y"], ["D", "~/q"]])
        XCTAssertEqual(line.arguments, "~/arg")
    }

    func testQuotedCommandWord() throws {
        let line = try parse(#""/Users/me/My Tools/claude" --foo"#)
        XCTAssertEqual(line.command, "/Users/me/My Tools/claude")
        XCTAssertEqual(line.arguments, "--foo")
    }

    func testEmptyValueAndEquality() throws {
        XCTAssertEqual(pairs(try parse("A= claude")), [["A", ""]])
        XCTAssertEqual(try parse("A=1 claude -p"), try parse("A='1'   claude -p"))
        XCTAssertNotEqual(try parse("A=1 claude"), try parse("A=2 claude"))
        XCTAssertNotEqual(try parse("A=1 claude"), try parse("claude"))
    }
}
