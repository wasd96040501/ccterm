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

    // MARK: - extractTag

    func test_extractTag_titleBasic() {
        XCTAssertEqual(Prompt.extractTag("title", from: "<title>Fix login bug</title>"), "Fix login bug")
    }

    func test_extractTag_surroundedByText() {
        let text = "Here is the answer:\n<title>Add dark mode toggle</title>\nthanks!"
        XCTAssertEqual(Prompt.extractTag("title", from: text), "Add dark mode toggle")
    }

    func test_extractTag_trimsWhitespace() {
        XCTAssertEqual(Prompt.extractTag("title", from: "<title>  Hello  </title>"), "Hello")
    }

    func test_extractTag_missingTagReturnsNil() {
        XCTAssertNil(Prompt.extractTag("title", from: "No tag here"))
        XCTAssertNil(Prompt.extractTag("title", from: "<title>no close"))
    }

    func test_extractTag_multipleTagsIndependent() {
        let text = "<title>English here</title>\n<title_i18n>中文在这</title_i18n>"
        XCTAssertEqual(Prompt.extractTag("title", from: text), "English here")
        XCTAssertEqual(Prompt.extractTag("title_i18n", from: text), "中文在这")
    }

    func test_extractTitle_backCompat() {
        XCTAssertEqual(Prompt.extractTitle(from: "<title>legacy</title>"), "legacy")
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

        let debug = """
        ===TITLE_GEN===
        firstMessage: \(firstMessage)
        title:        \(result.title)
        titleI18n:    \(result.titleI18n)
        branch:       \(result.branch)
        ===END===
        """
        NSLog("%@", debug)
        FileHandle.standardError.write(Data((debug + "\n").utf8))

        XCTAssertFalse(result.title.isEmpty, "title should not be empty")
        XCTAssertFalse(result.titleI18n.isEmpty, "titleI18n should not be empty")
        XCTAssertLessThanOrEqual(result.title.count, 120, "title should be reasonably short")

        // title 强制英文 → branch 应有 ASCII alnum → 必出 claude/<slug>。
        XCTAssertTrue(result.branch.hasPrefix("claude/"), "branch should start with claude/, got: \(result.branch)")
        let body = result.branch.replacingOccurrences(of: "claude/", with: "")
        XCTAssertFalse(body.isEmpty, "branch body should not be empty")
        XCTAssertLessThanOrEqual(body.count, 50, "branch body should be ≤ 50 chars")
    }

    func test_runTitleAndBranch_chineseInputYieldsChineseI18n() async throws {
        if ProcessInfo.processInfo.environment["SKIP_CLI_TESTS"] != nil {
            throw XCTSkip("SKIP_CLI_TESTS set")
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("title-zh-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let firstMessage = "修复用户输入空密码时登录页面崩溃的问题"
        let result = try await Prompt.runTitleAndBranch(
            firstMessage: firstMessage,
            configuration: PromptConfiguration(workingDirectory: tmp)
        )

        let debug = """
        ===TITLE_GEN_ZH===
        firstMessage: \(firstMessage)
        title:        \(result.title)
        titleI18n:    \(result.titleI18n)
        branch:       \(result.branch)
        ===END===
        """
        NSLog("%@", debug)
        FileHandle.standardError.write(Data((debug + "\n").utf8))

        XCTAssertFalse(result.title.isEmpty)
        XCTAssertFalse(result.titleI18n.isEmpty)
        // title 必须英文（ASCII）——因为 branch 依赖它
        XCTAssertTrue(result.branch.hasPrefix("claude/"), "English title should yield claude/ branch, got: \(result.branch)")
        // titleI18n 应和 title 不相同（中文输入理应给中文 i18n）
        XCTAssertNotEqual(result.title, result.titleI18n, "Chinese input should produce a non-English titleI18n")
        // titleI18n 至少含一个非 ASCII 字符
        let hasNonAscii = result.titleI18n.unicodeScalars.contains { !$0.isASCII }
        XCTAssertTrue(hasNonAscii, "titleI18n should contain non-ASCII chars for Chinese input, got: \(result.titleI18n)")
    }
}
