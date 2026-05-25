import AgentSDK
import XCTest

@testable import ccterm

/// Tests for the uniform tool-result error card.
///
/// Two layers:
///
/// 1. **Bridge** — `ToolUseToChild` (via `MessageEntryBlockBuilder`)
///    extracts the wrapper-level error text from a failed `tool_result`,
///    strips the `<tool_use_error>` envelope, and surfaces it on the
///    child's `errorText`. A failed `read` suppresses its file-content
///    card so the error string is not also rendered as fake content.
/// 2. **Layout** — `ToolGroupChildLayout` composes a uniform red error
///    card below every kind's body, giving even header-only (`generic`)
///    and diff-bearing (`fileEdit`) children a selectable + searchable
///    error band when expanded. Also pins the bash `stderr` render path.
@MainActor
final class ToolGroupErrorCardTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    /// Build a `ToolResultPayload` the same way `SessionRuntime.receive`
    /// does — resolve a user `tool_result` message and project its block
    /// + typed result. Mirrors `action(for:)`'s `.merge` construction.
    private func toolResult(
        toolUseId: String, text: String, isError: Bool
    ) -> ToolResultPayload {
        let msg = Message2Fixtures.userToolResult(
            toolUseId: toolUseId, text: text, isError: isError)
        guard case .user(let u) = msg, let item = u.toolResultBlock else {
            fatalError("fixture must carry a tool_result block")
        }
        return ToolResultPayload(item: item, typed: u.toolUseResult)
    }

    /// A single-tool `read` entry paired with its (possibly failed)
    /// tool_result, run through the production block builder.
    private func readChild(
        resultText: String, isError: Bool
    ) -> ToolGroupBlock.Child {
        let entry = MessageEntry.single(
            SingleEntry(
                id: UUID(),
                payload: .remote(
                    Message2Fixtures.assistantRead(
                        toolUseId: "tu_1", filePath: "/tmp/foo.swift")),
                delivery: nil,
                toolResults: [
                    "tu_1": toolResult(
                        toolUseId: "tu_1", text: resultText, isError: isError)
                ]))
        let blocks = MessageEntryBlockBuilder.entryBlocks(entry)
        guard case .toolGroup(let group) = blocks[0].kind,
            let child = group.children.first
        else { fatalError("expected a single-child tool group") }
        return child
    }

    private func expandedLayout(
        for child: ToolGroupBlock.Child, maxWidth: CGFloat = 600
    ) -> ToolGroupLayout {
        let groupId = UUID()
        let group = ToolGroupBlock(
            activeTitle: "Working",
            expandedActiveTitle: "Working",
            completedTitle: "Done",
            children: [child])
        return ToolGroupLayout.make(
            blockId: groupId,
            group: group,
            foldStates: [groupId: true, child.id: true],
            statusStates: [:],
            childHighlights: [:],
            maxWidth: maxWidth)
    }

    private func searchableTexts(_ layout: ToolGroupLayout) -> [String] {
        (layout.selectionAdapter?.searchableRegions() ?? []).map { $0.text }
    }

    // MARK: - Bridge extraction

    /// A failed result wrapped in `<tool_use_error>…</tool_use_error>`
    /// strips the envelope and surfaces the inner message on `errorText`.
    func testToolUseErrorEnvelopeStripped() {
        let child = readChild(
            resultText: "<tool_use_error>File does not exist.</tool_use_error>",
            isError: true)
        XCTAssertEqual(child.errorText, "File does not exist.")
    }

    /// A plain (un-enveloped) error string passes through, trimmed.
    func testPlainErrorTextPassesThrough() {
        let child = readChild(
            resultText: "EISDIR: illegal operation on a directory\n",
            isError: true)
        XCTAssertEqual(
            child.errorText, "EISDIR: illegal operation on a directory")
    }

    /// A successful result carries no error text.
    func testSuccessfulResultHasNoErrorText() {
        let child = readChild(resultText: "1\tlet x = 1", isError: false)
        XCTAssertNil(child.errorText)
    }

    /// On a `read` error the file-content card is suppressed so the error
    /// string isn't also rendered as fake new-file content — only the
    /// dedicated red error card shows it.
    func testReadErrorSuppressesFileContentCard() {
        let child = readChild(
            resultText: "<tool_use_error>boom</tool_use_error>", isError: true)
        guard case .read(let r) = child else {
            return XCTFail("expected a read child, got \(child)")
        }
        XCTAssertNil(r.content, "error result must not populate the content card")
        XCTAssertEqual(r.errorText, "boom")
    }

    /// An error gives an otherwise header-only kind an expandable body so
    /// it can host the error card. (`read` without content is header-only
    /// until a result lands; the error result makes it foldable.)
    func testErrorMakesChildExpandable() {
        let errored = readChild(
            resultText: "<tool_use_error>nope</tool_use_error>", isError: true)
        XCTAssertTrue(
            errored.hasExpandableBody,
            "a failed result must give the child a body to host the error card")

        let generic = ToolGroupBlock.Child.generic(
            GenericChild(id: UUID(), label: "Skill", activeLabel: "Using skill"))
        XCTAssertFalse(
            generic.hasExpandableBody, "header-only generic stays header-only")
        let genericErrored = ToolGroupBlock.Child.generic(
            GenericChild(
                id: UUID(), label: "Skill", activeLabel: "Using skill",
                errorText: "Unknown skill: commit"))
        XCTAssertTrue(
            genericErrored.hasExpandableBody,
            "a failed generic tool gains a body for the error card")
    }

    // MARK: - Layout composition

    /// An expanded header-only `generic` child with an error renders a
    /// body whose error text is selectable + searchable.
    func testGenericErrorCardIsSearchable() {
        let child = ToolGroupBlock.Child.generic(
            GenericChild(
                id: UUID(), label: "Skill", activeLabel: "Using skill",
                errorText: "Unknown skill: commit"))
        let layout = expandedLayout(for: child)

        XCTAssertNotNil(
            layout.selectionAdapter,
            "an expanded error card must publish a selection adapter")
        XCTAssertTrue(
            searchableTexts(layout).contains { $0.contains("Unknown skill: commit") },
            "the error text must be searchable")
    }

    /// A failed `fileEdit` keeps its diff body **and** gains the error
    /// card — both bands are selectable, on different `LayoutPosition`
    /// cases that never collide.
    func testFileEditErrorKeepsDiffAndAddsErrorCard() {
        let child = ToolGroupBlock.Child.fileEdit(
            FileEditChild(
                id: UUID(),
                label: "Edit foo.swift",
                activeLabel: "Editing foo.swift",
                filePath: "foo.swift",
                diff: DiffBlock(
                    filePath: "foo.swift",
                    oldString: "let x = 1",
                    newString: "let x = 2"),
                errorText: "patch failed to apply"))
        let layout = expandedLayout(for: child)

        let texts = searchableTexts(layout)
        XCTAssertTrue(
            texts.contains { $0.contains("patch failed to apply") },
            "error card text must be searchable")
        XCTAssertTrue(
            texts.contains { $0.contains("let x = 2") },
            "the diff body must remain searchable alongside the error card")
    }

    /// Bash `stderr` (success path) renders into a selectable body card —
    /// the data flows `BashChild.stderr` → `BashChildLayout`. Pins the
    /// "stderr is shown" contract.
    func testBashStderrIsRendered() {
        let child = ToolGroupBlock.Child.bash(
            BashChild(
                id: UUID(),
                label: "Ran 'build'",
                activeLabel: "Running 'build'",
                command: "build",
                stdout: "ok",
                stderr: "warning: deprecated API"))
        let layout = expandedLayout(for: child)

        XCTAssertTrue(
            searchableTexts(layout).contains { $0.contains("warning: deprecated API") },
            "bash stderr must render into a selectable body card")
    }

    /// A successful child with no error contributes no error card — the
    /// error path is strictly opt-in on `errorText`.
    func testNoErrorMeansNoErrorCard() {
        let child = ToolGroupBlock.Child.bash(
            BashChild(
                id: UUID(),
                label: "Ran 'ls'",
                activeLabel: "Running 'ls'",
                command: "ls",
                stdout: "apple",
                stderr: nil))
        let layout = expandedLayout(for: child)
        let texts = searchableTexts(layout)
        XCTAssertTrue(texts.contains { $0.contains("apple") })
        // No red error band — only the command + stdout cards.
        XCTAssertFalse(texts.contains { $0.lowercased().contains("error") })
    }
}
