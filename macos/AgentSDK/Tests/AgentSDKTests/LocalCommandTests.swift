import XCTest

@testable import AgentSDK

/// Local commands read from the tags the CLI writes into user text.
final class LocalCommandTests: XCTestCase {
    private func command(_ text: String) -> UserMessage.LocalCommand? {
        UserMessage(content: [.text(text)]).localCommand
    }

    func testSlashCommandWithArguments() {
        let text = """
            <command-message>model</command-message>
            <command-name>/model</command-name>
            <command-args>opus</command-args>
            """
        XCTAssertEqual(command(text), .input("/model opus"))
    }

    func testShellCommand() {
        XCTAssertEqual(command("<bash-input>ls -la</bash-input>"), .input("!ls -la"))
    }

    func testTagNamesMatchInAnyCase() {
        XCTAssertEqual(command("<Command-Name>/compact</COMMAND-NAME>"), .input("/compact"))
    }

    func testOutputKeepsElementsNestedUnderTheSameName() {
        let text = "<local-command-stdout>a <local-command-stdout>b</local-command-stdout> c</local-command-stdout>"
        XCTAssertEqual(
            command(text),
            .output(standardOutput: "a <local-command-stdout>b</local-command-stdout> c", standardError: ""))
    }

    func testTextThatIsNotOnlyTagsIsNoCommand() {
        XCTAssertNil(command("<command-name>/compact</command-name> and then some"))
        XCTAssertNil(command("<command-name>/compact"))
        XCTAssertNil(command("Run <bash-input>ls</bash-input>"))
    }
}
