import XCTest

@testable import AgentSDK

/// The pure parts of `CLIVersion` and of `SessionDirectory(configuration:)`;
/// none of these spawns a shell.
final class CLIProbeTests: XCTestCase {
    // MARK: - Version

    func testVersionParsing() {
        XCTAssertEqual(CLIVersion.version(in: "2.1.284 (Claude Code)\n"), "2.1.284")
        XCTAssertEqual(CLIVersion.version(in: "noise\nclaude 10.20.30-beta\n"), "10.20.30")
        XCTAssertNil(CLIVersion.version(in: "command not found: claude"))
        XCTAssertNil(CLIVersion.version(in: "2.1"))
    }

    // MARK: - Alias output

    func testZshAliasForms() {
        XCTAssertEqual(ShellEnvironment.parseAlias("orange='A=1 claude --x'\n", word: "orange"), "A=1 claude --x")
        XCTAssertEqual(ShellEnvironment.parseAlias("orange=claude\n", word: "orange"), "claude")
        XCTAssertEqual(
            ShellEnvironment.parseAlias(#"orange='A='\''x y'\'' claude'"#, word: "orange"), "A='x y' claude")
    }

    func testBashAliasForm() {
        XCTAssertEqual(ShellEnvironment.parseAlias("alias orange='A=1 claude'\n", word: "orange"), "A=1 claude")
    }

    func testNoAliasOutput() {
        XCTAssertNil(ShellEnvironment.parseAlias("", word: "orange"))
        XCTAssertNil(ShellEnvironment.parseAlias("other='x'", word: "orange"))
    }

    func testProbeOutputSplitsEnvironmentAndAlias() throws {
        let output = "HOME=/Users/me\nCLAUDE_CONFIG_DIR=/a=b\n\n__CCTERM_ALIAS__\norange='X=1 claude'\n"
        let probe = try XCTUnwrap(ShellEnvironment.parse(output, aliasFor: "orange"))
        XCTAssertEqual(probe.environment, ["HOME": "/Users/me", "CLAUDE_CONFIG_DIR": "/a=b"])
        XCTAssertEqual(probe.alias, "X=1 claude")
    }

    func testProbeOutputWithoutAliasOrEnvironment() throws {
        let probe = try XCTUnwrap(ShellEnvironment.parse("A=1\n\n__CCTERM_ALIAS__\n", aliasFor: "orange"))
        XCTAssertNil(probe.alias)
        XCTAssertNil(ShellEnvironment.parse("", aliasFor: nil))
    }

    // MARK: - Environment folding

    func testFoldingPrecedence() {
        let base = ["CLAUDE_CONFIG_DIR": "/rc", "KEEP": "base", "A": "base"]
        let line = LaunchLine("A=prefix B=prefix claude")
        let folded = SessionDirectory.environment(
            base: base, configuration: ["CLAUDE_CONFIG_DIR": "/config", "A": "config"], launch: line, alias: nil)
        XCTAssertEqual(folded["CLAUDE_CONFIG_DIR"], "/config")
        XCTAssertEqual(folded["KEEP"], "base")
        XCTAssertEqual(folded["A"], "prefix")
        XCTAssertEqual(folded["B"], "prefix")
    }

    func testAliasAssignmentsBeatThePrefix() {
        let folded = SessionDirectory.environment(
            base: [:], configuration: [:], launch: LaunchLine("A=1 B=1 orange"),
            alias: "A=2 CLAUDE_CONFIG_DIR=/alias claude")
        XCTAssertEqual(folded["A"], "2")
        XCTAssertEqual(folded["B"], "1")
        XCTAssertEqual(folded["CLAUDE_CONFIG_DIR"], "/alias")
    }

    func testFoldedConfigDirectoryDecidesTheProjectsDirectory() {
        let folded = SessionDirectory.environment(
            base: [:], configuration: ["CLAUDE_CONFIG_DIR": "/cfg"], launch: nil, alias: nil)
        XCTAssertEqual(SessionDirectory(environment: folded).url.path, "/cfg/projects")
    }
}
