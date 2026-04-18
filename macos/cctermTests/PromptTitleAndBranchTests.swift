import XCTest
import AgentSDK

/// 验证 `Prompt.runTitleAndBranch`：纯函数部分（slugify / extractTitle）
/// 以及一个真实调用 claude CLI 的集成 smoke test。
///
/// 集成 test 会真起 `claude -p` 子进程发一次 LLM。默认跑，可通过
/// 环境变量 `SKIP_CLI_TESTS=1` 在 CI 或无 CLI 环境下跳过。
final class PromptTitleAndBranchTests: XCTestCase {

    // MARK: - slugifyToBranch

    func test_slugify_matchesJMrExamples() {
        XCTAssertEqual(
            Prompt.slugifyToBranch("Fix login button not working on mobile"),
            "claude/fix-login-button-not-working-on-mobile"
        )
        XCTAssertEqual(
            Prompt.slugifyToBranch("Update README with installation instructions"),
            "claude/update-readme-with-installation-instructions"
        )
        XCTAssertEqual(
            Prompt.slugifyToBranch("Improve performance of data processing script"),
            "claude/improve-performance-of-data-processing-script"
        )
    }

    func test_slugify_emptyAndAllSymbols() {
        XCTAssertEqual(Prompt.slugifyToBranch(""), "")
        XCTAssertEqual(Prompt.slugifyToBranch("!!!"), "")
        XCTAssertEqual(Prompt.slugifyToBranch("  ...  "), "")
    }

    func test_slugify_collapsesRunsOfSeparators() {
        XCTAssertEqual(Prompt.slugifyToBranch("Hello   world!!!"), "claude/hello-world")
        XCTAssertEqual(Prompt.slugifyToBranch("--foo--bar--"), "claude/foo-bar")
    }

    func test_slugify_truncatesTo50AndTrimsTrailingDash() {
        let long = String(repeating: "a", count: 60)
        let out = Prompt.slugifyToBranch(long)
        let body = out.replacingOccurrences(of: "claude/", with: "")
        XCTAssertLessThanOrEqual(body.count, 50)
        XCTAssertFalse(body.hasSuffix("-"))
    }

    func test_slugify_nonAsciiTreatedAsSeparator() {
        // JMr 是 ASCII-only：[^a-z0-9]+ → -
        XCTAssertEqual(Prompt.slugifyToBranch("修 bug 漏洞"), "claude/bug")
        XCTAssertEqual(Prompt.slugifyToBranch("café latté"), "claude/caf-latt")
    }

    // MARK: - extractTitle

    func test_extractTitle_basic() {
        XCTAssertEqual(Prompt.extractTitle(from: "<title>Fix login bug</title>"), "Fix login bug")
    }

    func test_extractTitle_surroundedByText() {
        let text = "Here is the answer:\n<title>Add dark mode toggle</title>\nthanks!"
        XCTAssertEqual(Prompt.extractTitle(from: text), "Add dark mode toggle")
    }

    func test_extractTitle_trimsWhitespace() {
        XCTAssertEqual(Prompt.extractTitle(from: "<title>  Hello  </title>"), "Hello")
    }

    func test_extractTitle_missingTagReturnsNil() {
        XCTAssertNil(Prompt.extractTitle(from: "No tag here"))
        XCTAssertNil(Prompt.extractTitle(from: "<title>no close"))
    }

    // MARK: - Integration (real CLI)

    func test_runTitleAndBranch_integration() async throws {
        if ProcessInfo.processInfo.environment["SKIP_CLI_TESTS"] != nil {
            throw XCTSkip("SKIP_CLI_TESTS set")
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("title-and-branch-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let firstMessage = "Fix the login page crashing when users enter an empty password"
        let result = try await Prompt.runTitleAndBranch(
            firstMessage: firstMessage,
            configuration: PromptConfiguration(workingDirectory: tmp)
        )

        NSLog("[PromptTitleAndBranchTests] firstMessage: %@", firstMessage)
        NSLog("[PromptTitleAndBranchTests] title: %@", result.title)
        NSLog("[PromptTitleAndBranchTests] branch: %@", result.branch)
        // NSLog in XCTest sometimes routes to os_log instead of stdout — mirror via fputs to stderr.
        FileHandle.standardError.write(Data("===TITLE_GEN===\nfirstMessage: \(firstMessage)\ntitle: \(result.title)\nbranch: \(result.branch)\n===END===\n".utf8))

        XCTAssertFalse(result.title.isEmpty, "title should not be empty")
        XCTAssertLessThanOrEqual(result.title.count, 120, "title should be reasonably short")

        // JMr 行为：ASCII 无 alnum 时 branch 就是空串（调用方 fallback）。
        // 只要 title 带 ASCII 字母/数字，branch 必须是 claude/<slug> 且 body ≤ 50。
        let titleHasAscii = result.title.lowercased().unicodeScalars.contains { scalar in
            (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9")
        }
        if titleHasAscii {
            XCTAssertTrue(result.branch.hasPrefix("claude/"), "branch should start with claude/, got: \(result.branch)")
            let body = result.branch.replacingOccurrences(of: "claude/", with: "")
            XCTAssertFalse(body.isEmpty, "branch body should not be empty for ASCII title")
            XCTAssertLessThanOrEqual(body.count, 50, "branch body should be ≤ 50 chars")
        } else {
            XCTAssertEqual(result.branch, "", "non-ASCII title should yield empty branch")
        }
    }
}
