import AgentSDK
import XCTest

@testable import ccterm

/// Pins the slash-command **description** contract on `SessionRuntime`.
///
/// The completion popup's footer renders `SlashCommand.description`,
/// sourced from `session.slashCommands`. Two CLI surfaces feed that list
/// with different fidelity:
///
/// - The bootstrap `initialize(promptSuggestions:)` response carries
///   `commands: [SlashCommandInfo]` — name **and** description.
/// - The recurring `system.init` stream message carries
///   `slash_commands: [String]` — names **only**.
///
/// A prior version stored neither the bootstrap descriptions nor merged
/// them on adopt: `system.init` overwrote `slashCommands` with
/// `description: nil`, so any session that had received an init (i.e. an
/// already-CLI-started / resumed session) lost its descriptions while a
/// brand-new session — whose popup falls back to the desc-rich temp-CLI
/// fetch — kept them. These tests reproduce that asymmetry and lock the
/// merge.
@MainActor
final class SessionRuntimeSlashCommandsTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    private func makeRuntime() -> (SessionRuntime, FakeCLIClient) {
        let fake = FakeCLIClient()
        let runtime = SessionRuntime(
            sessionId: UUID().uuidString,
            repository: InMemorySessionRepository(),
            cliClientFactory: { _ in fake }
        )
        runtime.config.cwd = "/tmp/slash-command-tests"
        return (runtime, fake)
    }

    /// Drive bootstrap to attached + `.idle`, completing `initialize`
    /// with `response` (the desc-rich command catalog under test).
    private func bootstrap(
        _ runtime: SessionRuntime,
        _ fake: FakeCLIClient,
        response: InitializeResponse?
    ) async {
        runtime.activate()
        for _ in 0..<16 {
            await Task.yield()
            if !fake.initializeCalls.isEmpty { break }
        }
        XCTAssertFalse(fake.initializeCalls.isEmpty, "bootstrap should call initialize")
        fake.completeInitialize(with: response)
        for _ in 0..<16 {
            await Task.yield()
            if runtime.status == .idle { break }
        }
        XCTAssertEqual(runtime.status, .idle)
    }

    private func push(_ message: Message2, into fake: FakeCLIClient) async {
        fake.pushMessage(message)
        for _ in 0..<4 { await Task.yield() }
    }

    private func initializeResponse(
        _ commands: [(name: String, description: String?)]
    ) -> InitializeResponse {
        let json: [String: Any] = [
            "commands": commands.map { cmd -> [String: Any] in
                var d: [String: Any] = ["name": cmd.name]
                if let desc = cmd.description { d["description"] = desc }
                return d
            }
        ]
        return try! InitializeResponse(json: json)
    }

    private func descriptions(_ runtime: SessionRuntime) -> [String: String?] {
        Dictionary(uniqueKeysWithValues: runtime.slashCommands.map { ($0.name, $0.description) })
    }

    // MARK: - Tests

    /// Bootstrap alone seeds descriptions from the `initialize` response,
    /// before any `system.init` lands.
    func testBootstrapSeedsDescriptions() async {
        let (runtime, fake) = makeRuntime()
        await bootstrap(
            runtime, fake,
            response: initializeResponse([
                ("commit", "Create a commit"),
                ("review", "Review the diff"),
            ]))

        XCTAssertEqual(
            descriptions(runtime),
            ["commit": "Create a commit", "review": "Review the diff"])
    }

    /// The regression: a `system.init` (names only — the shape the CLI
    /// emits on every turn and on resume) must NOT wipe the descriptions
    /// the bootstrap response established.
    func testSystemInitPreservesBootstrapDescriptions() async {
        let (runtime, fake) = makeRuntime()
        await bootstrap(
            runtime, fake,
            response: initializeResponse([
                ("commit", "Create a commit"),
                ("review", "Review the diff"),
            ]))

        // A follow-up turn / resume init carrying names only.
        await push(
            Message2Fixtures.systemInit(slashCommands: ["commit", "review"]),
            into: fake)

        XCTAssertEqual(
            descriptions(runtime),
            ["commit": "Create a commit", "review": "Review the diff"],
            "system.init's name-only list must merge in cached descriptions, not null them")
    }

    /// A command present in `system.init` but absent from the bootstrap
    /// catalog simply has no description — merge is a lookup, not a filter.
    func testUnknownCommandInSystemInitHasNilDescription() async {
        let (runtime, fake) = makeRuntime()
        await bootstrap(
            runtime, fake,
            response: initializeResponse([("commit", "Create a commit")]))

        await push(
            Message2Fixtures.systemInit(slashCommands: ["commit", "mystery"]),
            into: fake)

        let descs = descriptions(runtime)
        XCTAssertEqual(descs["commit"], "Create a commit")
        XCTAssertEqual(descs["mystery"], String?.none)
        XCTAssertEqual(runtime.slashCommands.count, 2)
    }
}
