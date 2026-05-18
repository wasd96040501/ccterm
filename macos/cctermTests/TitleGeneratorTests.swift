import AgentSDK
import XCTest

@testable import ccterm

/// Exercises `TitleGenerator.generate` through its injectable runner
/// seam — no real LLM call, no CLI subprocess. The runner closure is
/// the only place where the real `Prompt.runTitleAndBranch` would run
/// in production, so flipping it lets these tests assert on:
/// - what argument the runner receives (firstMessage / customCommand /
///   workingDirectory shape)
/// - what `generate` returns for success vs throwing runners
/// - that the scratch workingDirectory is cleaned up on the success
///   path (defer runs)
final class TitleGeneratorTests: XCTestCase {

    /// Sendable capture box for runner-supplied state. The runner is
    /// `@Sendable`, so anything it writes must cross actor boundaries
    /// — a plain `var` in the test method won't compile. An actor
    /// suffices.
    private actor Capture {
        var firstMessage: String?
        var customCommand: String?
        var workingDirectory: URL?

        func record(message: String, config: PromptConfiguration) {
            firstMessage = message
            customCommand = config.customCommand
            workingDirectory = config.workingDirectory
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
        ) { msg, config in
            await capture.record(message: msg, config: config)
            return Prompt.TitleAndBranch(
                title: "Fix login bug",
                titleI18n: "Fix login bug",
                branch: "fix-login-bug"
            )
        }

        let firstMessage = await capture.firstMessage
        let customCommand = await capture.customCommand
        let workingDirectory = await capture.workingDirectory
        XCTAssertEqual(firstMessage, "Fix the login bug")
        XCTAssertEqual(customCommand, "trae-proxy claude --")
        XCTAssertTrue(
            workingDirectory?.path.contains("title-gen-") ?? false,
            "workingDirectory should be a unique title-gen-<prefix> scratch dir")
        XCTAssertEqual(result?.titleI18n, "Fix login bug")
    }

    func testCustomCommandNilPassesThrough() async {
        let capture = Capture()

        _ = await TitleGenerator.generate(
            firstMessage: "irrelevant",
            customCLICommand: nil
        ) { msg, config in
            await capture.record(message: msg, config: config)
            return Prompt.TitleAndBranch(title: "x", titleI18n: "x", branch: "y")
        }

        let customCommand = await capture.customCommand
        XCTAssertNil(customCommand, "nil customCLICommand must round-trip as nil on PromptConfiguration")
    }

    // MARK: - Success / failure handling

    func testRunnerSuccessReturnsValue() async {
        let expected = Prompt.TitleAndBranch(
            title: "Add dark mode",
            titleI18n: "Add dark mode",
            branch: "dark-mode")
        let result = await TitleGenerator.generate(
            firstMessage: "Add dark mode toggle",
            customCLICommand: nil
        ) { _, _ in expected }

        XCTAssertEqual(result?.title, "Add dark mode")
        XCTAssertEqual(result?.titleI18n, "Add dark mode")
        XCTAssertEqual(result?.branch, "dark-mode")
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
        ) { msg, config in
            await capture.record(message: msg, config: config)
            return Prompt.TitleAndBranch(title: "x", titleI18n: "x", branch: "y")
        }

        guard let used = await capture.workingDirectory else {
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
        ) { msg, config in
            await capture.record(message: msg, config: config)
            throw Boom()
        }

        guard let used = await capture.workingDirectory else {
            XCTFail("runner never received a workingDirectory")
            return
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: used.path),
            "scratch dir must be removed even when the runner throws")
    }
}
