import Foundation

extension Prompt {

    /// Generates a title and (derived from the title) branch name in a single LLM call.
    ///
    /// Ported from Claude.app's `/dust/generate_title_and_branch`:
    /// - spawn a one-shot `claude -p` subprocess with the full prompt inlined (built-in coding-session template)
    /// - disable tools (`--tools ""`)
    /// - regex-extract `<title>...</title>` from the model response
    /// - branch = `claude/<slugify(title).prefix(50)>` (pure string derivation, no second LLM call)
    ///
    /// Differences vs. `run(message:configuration:)`: the prompt is built in,
    /// the return value is typed, and it has its own timeout.
    ///
    /// `firstMessage` is head-truncated to `maxDescriptionChars` (default 2000 chars, ~500 tokens)
    /// so a long pasted diff / code blob does not blow up the token budget — the title intent
    /// is almost always at the start.
    public static func runTitleAndBranch(
        firstMessage: String,
        configuration: PromptConfiguration,
        timeout: TimeInterval = 30,
        maxDescriptionChars: Int = 2000
    ) async throws -> TitleAndBranch {
        let description = truncateHead(firstMessage, to: maxDescriptionChars)
        let filledPrompt = codingTitlePrompt.replacingOccurrences(
            of: "{session_description}",
            with: description
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
                let resultText = json["result"] as? String
            else {
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

            // Fall back to `title` when title_i18n is missing so the field is never empty.
            let titleI18n = extractTag("title_i18n", from: resultText) ?? title
            let branch = slugifyToBranch(title)
            return TitleAndBranch(title: title, titleI18n: titleI18n, branch: branch)
        }.value
    }

    public struct TitleAndBranch: Sendable, Equatable {
        /// English title (always English — used for the branch slug).
        public let title: String
        /// Title in the same language as the user input. Equals `title` when the input was English.
        public let titleI18n: String
        /// `claude/<slug(title).prefix(50)>`, or empty when the title has no ASCII to slug.
        public let branch: String

        public init(title: String, titleI18n: String, branch: String) {
            self.title = title
            self.titleI18n = titleI18n
            self.branch = branch
        }
    }

    /// Direct port of Claude.app's `JMr`:
    /// `title.toLowerCase().replace(/[^a-z0-9]+/g,"-").replace(/^-+|-+$/g,"").slice(0,50).replace(/-+$/,"")`.
    /// Prefixes `claude/` when non-empty, returns empty string otherwise.
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

    /// Kept for backwards compatibility: extracts `<title>...</title>` from an LLM reply.
    public static func extractTitle(from text: String) -> String? {
        extractTag("title", from: text)
    }

    /// Head-truncates `text`: when longer than `limit` characters, returns the first `limit`
    /// characters with a trailing `" …"` marker. Counts grapheme clusters via `String.Index`,
    /// so it is safe for mixed-script text.
    public static func truncateHead(_ text: String, to limit: Int) -> String {
        guard limit > 0, text.count > limit else { return text }
        return String(text.prefix(limit)) + " …"
    }

    /// Generic single-tag extractor: returns the trimmed contents of the first `<tag>…</tag>`,
    /// or nil if missing or empty.
    public static func extractTag(_ tag: String, from text: String) -> String? {
        let openTag = "<\(tag)>"
        let closeTag = "</\(tag)>"
        guard let start = text.range(of: openTag),
            let end = text.range(of: closeTag, range: start.upperBound..<text.endIndex)
        else {
            return nil
        }
        let inner = text[start.upperBound..<end.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? nil : inner
    }

    /// Same semantics as `resolveExecutable`, but kept separate so the original `run`
    /// implementation stays untouched.
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
            !resolved.isEmpty
        else {
            throw AgentSDKError.binaryNotFound
        }
        return resolved
    }

    /// Coding-session template, based on Claude.app's `HMr` (`/tmp/claude-index.beautified.js` L232130).
    /// Extended to require both an English `<title>` (used for the branch slug) and a
    /// `<title_i18n>` in the user's original language.
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
