import XCTest

@testable import ccterm

/// The `/new` + `/clear` builtin seam inside `SlashCommandTriggerRule`:
/// builtins are offered only when the context carries a dispatcher, filter
/// by the typed query, clear the input on confirm (vs splicing text), fire
/// the dispatcher, and shadow same-named CLI commands.
@MainActor
final class BuiltinSlashCommandTests: XCTestCase {

    private let rule = SlashCommandTriggerRule()

    /// Context whose `onBuiltinCommand` is non-nil so builtins are enabled.
    /// `directory` nil exercises the synchronous builtin-only provider path
    /// (the CLI store path is async + spawns a subprocess).
    private func ctx(
        directory: String? = nil,
        known: [SlashCommand]? = nil,
        onBuiltin: ((BuiltinSlashCommand) -> Void)? = { _ in }
    ) -> CompletionTriggerContext {
        CompletionTriggerContext(
            directory: directory,
            additionalDirs: [],
            pluginDirs: [],
            knownSlashCommands: known,
            onBuiltinCommand: onBuiltin)
    }

    /// Synchronously drain the (possibly main-async) provider callback.
    private func providerItems(
        _ session: CompletionViewModel.CompletionSession, query: String
    ) -> [any CompletionItem] {
        let exp = expectation(description: "provider")
        var out: [any CompletionItem] = []
        session.provider(query) { items in
            out = items
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
        return out
    }

    func test_builtins_offeredWhenDispatcherPresent() throws {
        let session = try XCTUnwrap(rule.match(text: "/", cursorLocation: 1, context: ctx()))
        let items = providerItems(session, query: "")
        let builtins = items.compactMap { ($0 as? BuiltinCompletionItem)?.command }
        XCTAssertEqual(Set(builtins), [.new, .clear])
    }

    func test_builtins_absentWhenDispatcherNil() throws {
        // Compose-card posture: no dispatcher → no builtins, and (no dir)
        // the popup falls back to the noDirectory empty state.
        let session = try XCTUnwrap(
            rule.match(text: "/", cursorLocation: 1, context: ctx(onBuiltin: nil)))
        let items = providerItems(session, query: "")
        XCTAssertTrue(items.isEmpty)
        XCTAssertEqual(session.emptyReasonOverride, .noDirectory)
    }

    func test_builtins_filteredByQuery() throws {
        let session = try XCTUnwrap(rule.match(text: "/", cursorLocation: 1, context: ctx()))
        let items = providerItems(session, query: "ne")
        let builtins = items.compactMap { ($0 as? BuiltinCompletionItem)?.command }
        XCTAssertEqual(builtins, [.new])
    }

    func test_builtinConfirm_clearsInputAndDispatches() throws {
        var dispatched: BuiltinSlashCommand?
        let session = try XCTUnwrap(
            rule.match(
                text: "/", cursorLocation: 1, context: ctx(onBuiltin: { dispatched = $0 })))
        let item = try XCTUnwrap(
            providerItems(session, query: "").first { $0 is BuiltinCompletionItem })

        // Builtin replacement clears the typed "/" (range 0..<1 → "").
        let replacement = session.makeReplacement(item, "/", 1)
        XCTAssertEqual(replacement.replacement, "")
        XCTAssertEqual(replacement.range, NSRange(location: 0, length: 1))

        // Confirm fires the dispatcher with the item's command.
        session.onItemConfirmed?(item)
        XCTAssertEqual(dispatched, (item as? BuiltinCompletionItem)?.command)
    }

    func test_cliCommand_stillSplicesText() throws {
        // A non-builtin item keeps the "/name " splice behavior.
        let session = try XCTUnwrap(rule.match(text: "/", cursorLocation: 1, context: ctx()))
        let cli = SlashCommandStore.Match(name: "commit", description: "c", rank: 0)
        let replacement = session.makeReplacement(cli, "/", 1)
        XCTAssertEqual(replacement.replacement, "/commit ")
    }

    func test_builtins_shadowSameNamedCLICommand() throws {
        // The knownSlashCommands path filters synchronously through the
        // store; a CLI "new" must be deduped in favor of the builtin so the
        // popup never shows two "/new" rows. "commit" survives.
        let known = [
            SlashCommand(name: "new", description: "cli new"),
            SlashCommand(name: "commit", description: "cli commit"),
        ]
        let session = try XCTUnwrap(
            rule.match(text: "/", cursorLocation: 1, context: ctx(directory: "/tmp", known: known)))
        let items = providerItems(session, query: "")
        let displayTexts = items.map(\.displayText)
        XCTAssertEqual(displayTexts.filter { $0 == "/new" }.count, 1)
        XCTAssertEqual(items.filter { $0 is BuiltinCompletionItem }.count, 2)
        XCTAssertTrue(displayTexts.contains("/commit"))
    }
}
