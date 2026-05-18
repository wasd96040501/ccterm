import AgentSDK
import Foundation

/// Runs the LLM call that produces a sidebar title (and a worktree
/// branch suggestion, currently discarded) for a session's first
/// message. Stateless: the handle owns `isGeneratingTitle` and `title`;
/// this type is just the I/O path that wraps `Prompt.runTitleAndBranch`
/// in a scratch temp directory.
///
/// Split off `SessionHandle2` so the LLM call is testable: the `runner`
/// parameter is injectable, so tests can assert on the path
/// (firstMessage / customCLICommand forwarded, errors swallowed to nil)
/// without firing a real CLI subprocess.
enum TitleGenerator {

    /// Underlying LLM call signature. Production wires
    /// `Prompt.runTitleAndBranch`; tests pass a closure that returns a
    /// canned response or throws.
    typealias Runner = @Sendable (String, PromptConfiguration) async throws -> Prompt.TitleAndBranch

    /// Production runner — the real LLM call.
    static let defaultRunner: Runner = { firstMessage, configuration in
        try await Prompt.runTitleAndBranch(
            firstMessage: firstMessage,
            configuration: configuration
        )
    }

    /// Generate a title/branch pair for `firstMessage`. Returns nil on
    /// any failure (network, parsing, CLI absent) — the caller (the
    /// handle's `generateTitle(from:)` facade) interprets nil as "keep
    /// the existing title."
    ///
    /// - Parameter customCLICommand: optional override read from
    ///   `UserDefaults` by the call site (the handle), so this function
    ///   stays pure and CI-safe.
    /// - Parameter runner: injection seam for tests. Production omits.
    static func generate(
        firstMessage: String,
        customCLICommand: String?,
        runner: Runner = defaultRunner
    ) async -> Prompt.TitleAndBranch? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("title-gen-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = PromptConfiguration(
            workingDirectory: tmp,
            customCommand: customCLICommand
        )
        do {
            return try await runner(firstMessage, config)
        } catch {
            appLog(
                .warning, "TitleGenerator",
                "title-gen failed: \(error.localizedDescription)")
            return nil
        }
    }
}
