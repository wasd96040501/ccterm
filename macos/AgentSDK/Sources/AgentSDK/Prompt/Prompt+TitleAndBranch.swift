import Foundation

extension Prompt {

    /// 一次 LLM 同时生成 title 和（从 title 派生的）branch name。
    ///
    /// 抄自 Claude.app 的 `/dust/generate_title_and_branch` 实现：
    /// - 起一次性 `claude -p` 子进程，inline 完整提示词（coding-session 模板内置）
    /// - 关闭工具（`--tools ""`）
    /// - model response 中正则抓取 `<title>...</title>`
    /// - branch = `claude/<slugify(title).prefix(50)>`（字符串派生，不做第二次 LLM）
    ///
    /// 与 `run(message:configuration:)` 的差异：提示词内置、返回 typed 结构、自带超时。
    public static func runTitleAndBranch(
        firstMessage: String,
        configuration: PromptConfiguration,
        timeout: TimeInterval = 30
    ) async throws -> TitleAndBranch {
        let filledPrompt = codingTitlePrompt.replacingOccurrences(
            of: "{session_description}",
            with: firstMessage
        )

        return try await Task.detached {
            let (executablePath, prefixArgs) = try resolveTitleExecutable(config: configuration)

            var args = prefixArgs
            args.append(contentsOf: [
                "-p",
                "--output-format", "json",
                "--no-session-persistence",
                "--tools", "",
            ])
            args.append("--")
            args.append(filledPrompt)

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executablePath)
            proc.arguments = args
            proc.currentDirectoryURL = configuration.workingDirectory

            var env = ShellEnvironment.loginEnvironment() ?? ProcessInfo.processInfo.environment
            env.removeValue(forKey: "CLAUDECODE")
            env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
            for (k, v) in configuration.env { env[k] = v }
            proc.environment = env

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            proc.standardOutput = stdoutPipe
            proc.standardError = stderrPipe

            NSLog("[AgentSDK.Prompt.TitleAndBranch] Launch: %@ %@", executablePath, args.joined(separator: " "))

            do {
                try proc.run()
            } catch {
                throw AgentSDKError.launchFailed(underlying: error)
            }

            let timeoutItem = DispatchWorkItem {
                if proc.isRunning { proc.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            timeoutItem.cancel()

            let exitCode = proc.terminationStatus
            guard exitCode == 0 else {
                let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
                let isTimeout = proc.terminationReason == .uncaughtSignal && !timeoutItem.isCancelled
                throw AgentSDKError.promptFailed(
                    exitCode: exitCode,
                    stderr: isTimeout ? "title-gen timed out after \(timeout)s" : stderrText
                )
            }

            guard let json = try? JSONSerialization.jsonObject(with: stdoutData) as? [String: Any],
                  let resultText = json["result"] as? String else {
                let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
                throw AgentSDKError.promptFailed(
                    exitCode: 0,
                    stderr: "Invalid JSON output: \(stdoutText.prefix(500))"
                )
            }

            guard let title = extractTag("title", from: resultText) else {
                throw AgentSDKError.promptFailed(
                    exitCode: 0,
                    stderr: "No <title> tag found in: \(resultText.prefix(200))"
                )
            }

            // title_i18n 缺失时 fallback 到 title，保证非空
            let titleI18n = extractTag("title_i18n", from: resultText) ?? title
            let branch = slugifyToBranch(title)
            return TitleAndBranch(title: title, titleI18n: titleI18n, branch: branch)
        }.value
    }

    public struct TitleAndBranch: Sendable, Equatable {
        /// 英文 title（固定英文，给 branch slug 用）。
        public let title: String
        /// 与用户输入同语言的 title。若输入是英文则等同 `title`。
        public let titleI18n: String
        /// `claude/<slug(title).prefix(50)>`，无 ASCII 可 slug 时为空串。
        public let branch: String
    }

    /// 照抄 Claude.app 的 `JMr`：
    /// `title.toLowerCase().replace(/[^a-z0-9]+/g,"-").replace(/^-+|-+$/g,"").slice(0,50).replace(/-+$/,"")`
    /// 非空则前缀 `claude/`，空则返回空串。
    public static func slugifyToBranch(_ title: String) -> String {
        let asciiAlnum: Set<Character> = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        var slug = ""
        var prevDash = false
        for ch in title.lowercased() {
            if asciiAlnum.contains(ch) {
                slug.append(ch)
                prevDash = false
            } else if !prevDash {
                slug.append("-")
                prevDash = true
            }
        }
        while slug.hasPrefix("-") { slug.removeFirst() }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.count > 50 { slug = String(slug.prefix(50)) }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "" : "claude/\(slug)"
    }

    /// 仍保留：LLM 回复里抓 `<title>...</title>`。历史兼容。
    public static func extractTitle(from text: String) -> String? {
        extractTag("title", from: text)
    }

    /// 通用单标签提取：第一处 `<tag>…</tag>` 之间的内容，trim 空白，空串返回 nil。
    public static func extractTag(_ tag: String, from text: String) -> String? {
        let openTag = "<\(tag)>"
        let closeTag = "</\(tag)>"
        guard let start = text.range(of: openTag),
              let end = text.range(of: closeTag, range: start.upperBound..<text.endIndex) else {
            return nil
        }
        let inner = text[start.upperBound..<end.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? nil : inner
    }

    /// 与 `resolveExecutable` 同语义，但不复用其 private 实现，保持 `run` 完全不动。
    private static func resolveTitleExecutable(
        config: PromptConfiguration
    ) throws -> (executablePath: String, prefixArgs: [String]) {
        if let customCommand = config.customCommand, !customCommand.isEmpty {
            let tokens = customCommand.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard var first = tokens.first else { throw AgentSDKError.binaryNotFound }
            if !first.hasPrefix("/") {
                first = try whichPath(for: first)
            }
            return (first, Array(tokens.dropFirst()))
        }
        guard let resolved = config.binaryPath ?? BinaryLocator.locate() else {
            throw AgentSDKError.binaryNotFound
        }
        return (resolved, [])
    }

    private static func whichPath(for name: String) throws -> String {
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = [name]
        which.environment = ShellEnvironment.loginEnvironment() ?? ProcessInfo.processInfo.environment
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        try which.run()
        which.waitUntilExit()
        guard which.terminationStatus == 0,
              let resolved = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !resolved.isEmpty else {
            throw AgentSDKError.binaryNotFound
        }
        return resolved
    }

    /// coding-session 模板，基于 Claude.app 的 `HMr`（`/tmp/claude-index.beautified.js` L232130）
    /// 扩展：要求同时输出英文 `<title>`（branch slug 用）和用户原语言的 `<title_i18n>`。
    fileprivate static let codingTitlePrompt = """
    You are coming up with a succinct title for a coding session based on the provided description. The title should be clear, concise, and accurately reflect the content of the coding task.
    You should keep it short and simple, ideally no more than 6 words. Avoid using jargon or overly technical terms unless absolutely necessary. The title should be easy to understand for anyone reading it.

    You must output TWO titles in XML tags, in this exact order:
    1. <title>…</title> — always in English, no more than 6 words. This is used for git branch naming, so it must be English regardless of the description language.
    2. <title_i18n>…</title_i18n> — same meaning as <title>, but in the SAME language as the user's description. If the description is already in English, repeat the English title verbatim.

    For example (English input):
    <title>Fix login button not working on mobile</title>
    <title_i18n>Fix login button not working on mobile</title_i18n>

    For example (Chinese input):
    <title>Fix empty-password login crash</title>
    <title_i18n>修复空密码登录崩溃</title_i18n>

    For example (Japanese input):
    <title>Add dark mode to settings</title>
    <title_i18n>設定にダークモードを追加</title_i18n>

    Here is the session description:
    <description>{session_description}</description>
    Please generate the two titles for this session.
    """
}
