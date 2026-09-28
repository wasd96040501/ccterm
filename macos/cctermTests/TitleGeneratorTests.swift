import AgentSDK
import XCTest

@testable import ccterm

/// Exercises `TitleGenerator.generate` through its injectable runner
/// seam — no real LLM call, no CLI subprocess. The runner stands in for
/// the one-shot `claude -p` call, so these tests assert on:
/// - the prompt and configuration the runner receives
/// - how the model's reply is parsed (`<title_i18n>` over `<title>`)
/// - that failures return nil
/// - that the scratch working directory is removed afterwards
final class TitleGeneratorTests: XCTestCase {

    /// Sendable capture box for runner-supplied state. The runner is
    /// `@Sendable`, so anything it writes must cross actor boundaries.
    private actor Capture {
        var prompt: String?
        var configuration: PromptConfiguration?

        func record(prompt: String, configuration: PromptConfiguration) {
            self.prompt = prompt
            self.configuration = configuration
        }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Forwarded args

    func testForwardsFirstMessageAndCustomCommandIntoConfig() async {
        let capture = Capture()

        let result = await TitleGenerator.generate(
            firstMessage: "Fix the login bug",
            customCLICommand: "trae-proxy claude --"
        ) { prompt, configuration in
            await capture.record(prompt: prompt, configuration: configuration)
            return "<title>Fix login bug</title>\n<title_i18n>Fix login bug</title_i18n>"
        }

        let prompt = await capture.prompt
        let configuration = await capture.configuration
        XCTAssertTrue(
            prompt?.contains("<description>Fix the login bug</description>") ?? false,
            "the first message is embedded in the template")
        XCTAssertEqual(configuration?.customCommand, "trae-proxy claude --")
        XCTAssertEqual(configuration?.tools, [], "title generation needs no tools")
        XCTAssertTrue(
            configuration?.workingDirectory.path.contains("title-gen-") ?? false,
            "workingDirectory should be a unique title-gen-<prefix> scratch dir")
        XCTAssertEqual(result, "Fix login bug")
    }

    func testCustomCommandNilPassesThrough() async {
        let capture = Capture()

        _ = await TitleGenerator.generate(
            firstMessage: "irrelevant",
            customCLICommand: nil
        ) { prompt, configuration in
            await capture.record(prompt: prompt, configuration: configuration)
            return "<title>x</title>"
        }

        let configuration = await capture.configuration
        XCTAssertNil(configuration?.customCommand, "nil customCLICommand must round-trip as nil")
    }

    func testLongFirstMessageIsTruncated() {
        let prompt = TitleGenerator.prompt(for: String(repeating: "a", count: 50), limit: 10)
        XCTAssertTrue(prompt.contains("<description>aaaaaaaaaa …</description>"))
    }

    // MARK: - Reply parsing

    func testPrefersLocalizedTitle() async {
        let result = await TitleGenerator.generate(firstMessage: "修复登录", customCLICommand: nil) { _, _ in
            "<title>Fix login</title>\n<title_i18n>修复登录</title_i18n>"
        }
        XCTAssertEqual(result, "修复登录")
    }

    func testFallsBackToEnglishTitle() async {
        let result = await TitleGenerator.generate(firstMessage: "x", customCLICommand: nil) { _, _ in
            "<title>  Add dark mode  </title>"
        }
        XCTAssertEqual(result, "Add dark mode", "tags are trimmed")
    }

    func testReplyWithoutTitleReturnsNil() async {
        let result = await TitleGenerator.generate(firstMessage: "x", customCLICommand: nil) { _, _ in
            "I can't help with that."
        }
        XCTAssertNil(result)
    }

    func testRunnerThrowingReturnsNil() async {
        struct Boom: Error {}
        let result = await TitleGenerator.generate(
            firstMessage: "x",
            customCLICommand: nil
        ) { _, _ in throw Boom() }

        XCTAssertNil(result, "any error from the runner must be swallowed and returned as nil")
    }

    // MARK: - Scratch dir cleanup

    func testWorkingDirIsCleanedUpAfterSuccess() async {
        let capture = Capture()

        _ = await TitleGenerator.generate(
            firstMessage: "x",
            customCLICommand: nil
        ) { prompt, configuration in
            await capture.record(prompt: prompt, configuration: configuration)
            return "<title>x</title>"
        }

        guard let used = await capture.configuration?.workingDirectory else {
            XCTFail("runner never received a workingDirectory")
            return
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: used.path),
            "generate()'s defer must remove the scratch dir after the runner returns")
    }

    func testWorkingDirIsCleanedUpAfterRunnerThrows() async {
        struct Boom: Error {}
        let capture = Capture()

        _ = await TitleGenerator.generate(
            firstMessage: "x",
            customCLICommand: nil
        ) { prompt, configuration in
            await capture.record(prompt: prompt, configuration: configuration)
            throw Boom()
        }

        guard let used = await capture.configuration?.workingDirectory else {
            XCTFail("runner never received a workingDirectory")
            return
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: used.path),
            "scratch dir must be removed even when the runner throws")
    }
}
