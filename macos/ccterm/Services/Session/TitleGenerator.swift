import AgentSDK
import Foundation

/// Names a session from its first message with a one-shot, tool-less CLI
/// call in a scratch directory. Stateless: the runtime owns
/// `isGeneratingTitle` and `title`.
///
/// The `runner` seam is the CLI call itself, so tests check the prompt,
/// configuration and reply parsing without spawning a process.
enum TitleGenerator {

    /// The one-shot call: prompt and configuration in, the model's reply out.
    typealias Runner = @Sendable (String, PromptConfiguration) async throws -> String

    /// Production runner — `claude -p`.
    static let defaultRunner: Runner = { prompt, configuration in
        try await Prompt.run(prompt, configuration: configuration).result ?? ""
    }

    /// The title in the language of `firstMessage`, or nil on any failure
    /// (CLI missing, timeout, unparseable reply) — the caller keeps its
    /// current title.
    ///
    /// - Parameter customCLICommand: read from `UserDefaults` by the caller
    ///   so this stays pure and CI-safe.
    static func generate(
        firstMessage: String,
        customCLICommand: String?,
        runner: Runner = defaultRunner
    ) async -> String? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("title-gen-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let configuration = PromptConfiguration(
            workingDirectory: tmp,
            tools: [],
            timeout: 30,
            customCommand: customCLICommand,
            env: ["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"]
        )
        do {
            let reply = try await runner(prompt(for: firstMessage), configuration)
            guard let title = tag("title_i18n", in: reply) ?? tag("title", in: reply) else {
                appLog(.warning, "TitleGenerator", "title-gen reply has no <title>: \(reply.prefix(200))")
                return nil
            }
            return title
        } catch {
            appLog(.warning, "TitleGenerator", "title-gen failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// The filled-in template. A long first message (a pasted diff, a log) is
    /// cut to its head — the intent is almost always at the start.
    static func prompt(for firstMessage: String, limit: Int = 2000) -> String {
        let description = firstMessage.count > limit ? String(firstMessage.prefix(limit)) + " …" : firstMessage
        return template.replacingOccurrences(of: "{session_description}", with: description)
    }

    /// The trimmed contents of the first `<name>…</name>`; nil when missing
    /// or empty.
    static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
            let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        let inner = text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? nil : inner
    }

    /// Claude.app's coding-session title template, extended to also ask for
    /// the title in the description's language (`<title_i18n>`).
    private static let template = """
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
