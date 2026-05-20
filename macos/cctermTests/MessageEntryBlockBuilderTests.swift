import AgentSDK
import XCTest

@testable import ccterm

/// Pure-logic tests for `MessageEntryBlockBuilder`. Each test builds a
/// throwaway `MessageEntry` and asserts on the resulting `[Block]` shape.
/// No filesystem, no SessionRuntime, no MainActor — these can run in
/// fully parallel processes.
final class MessageEntryBlockBuilderTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Single assistant text segment → one paragraph block. Smallest path.
    func testAssistantTextProducesParagraphBlock() {
        let entryId = UUID()
        let entry = MessageEntry.single(
            SingleEntry(
                id: entryId,
                payload: .remote(Message2Fixtures.assistantText("Hello world")),
                delivery: nil,
                toolResults: [:]))

        let blocks = MessageEntryBlockBuilder.entryBlocks(entry)

        XCTAssertEqual(blocks.count, 1, "single text segment should yield one block")
        guard case .paragraph = blocks[0].kind else {
            return XCTFail("expected .paragraph, got \(blocks[0].kind)")
        }
    }

    /// Assistant message with a single tool_use produces a single toolGroup
    /// block. This is the "single-tool host group" entry-bridge path.
    func testAssistantToolUseProducesToolGroupBlock() {
        let entry = MessageEntry.single(
            SingleEntry(
                id: UUID(),
                payload: .remote(
                    Message2Fixtures.assistantRead(
                        toolUseId: "tu_1", filePath: "/tmp/foo.swift")),
                delivery: nil,
                toolResults: [:]))

        let blocks = MessageEntryBlockBuilder.entryBlocks(entry)

        XCTAssertEqual(blocks.count, 1)
        guard case .toolGroup(let group) = blocks[0].kind else {
            return XCTFail("expected .toolGroup, got \(blocks[0].kind)")
        }
        XCTAssertEqual(
            group.children.count, 1,
            "single-tool host group should have exactly one child")
    }

    /// The user-bubble block id is derived from `entry.id` and must stay
    /// constant whether the payload is `.localUser` (pre-echo) or `.remote`
    /// (post-echo). This is what lets the bridge route the transition
    /// through `.update(id, kind)` instead of remove + insert.
    func testUserBubbleStableIdAcrossLocalToRemoteTransition() {
        let id = UUID()
        let localEntry = MessageEntry.single(
            SingleEntry(
                id: id,
                payload: .localUser(
                    LocalUserInput(text: "hi")),
                delivery: .queued,
                toolResults: [:]))
        let remoteEntry = MessageEntry.single(
            SingleEntry(
                id: id,
                payload: .remote(Message2Fixtures.userText("hi")),
                delivery: .confirmed,
                toolResults: [:]))

        let localBlocks = MessageEntryBlockBuilder.entryBlocks(localEntry)
        let remoteBlocks = MessageEntryBlockBuilder.entryBlocks(remoteEntry)

        XCTAssertEqual(localBlocks.count, 1)
        XCTAssertEqual(remoteBlocks.count, 1)
        XCTAssertEqual(
            localBlocks[0].id, remoteBlocks[0].id,
            "user bubble id must survive the localUser → remote transition")
    }
}
