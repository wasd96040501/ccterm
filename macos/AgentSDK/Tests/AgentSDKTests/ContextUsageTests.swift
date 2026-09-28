import XCTest

@testable import AgentSDK

/// Decoding the `get_context_usage` response.
final class ContextUsageTests: XCTestCase {

    func testParsesMinimalResponse() throws {
        let usage = try decode([
            "categories": [
                ["name": "Messages", "tokens": 74_600, "color": "purple"],
                ["name": "System tools", "tokens": 11_600, "color": "inactive"],
                ["name": "Autocompact buffer", "tokens": 33_000, "color": "inactive"],
                ["name": "Free space", "tokens": 869_600, "color": "promptBorder"],
            ],
            "totalTokens": 97_400,
            "maxTokens": 1_000_000,
            "rawMaxTokens": 1_000_000,
            "percentage": 10,
            "model": "claude-opus-4-7",
            "isAutoCompactEnabled": true,
            "memoryFiles": [],
            "mcpTools": [],
            "agents": [],
        ])
        XCTAssertEqual(usage.totalTokens, 97_400)
        XCTAssertEqual(usage.rawMaxTokens, 1_000_000)
        XCTAssertEqual(usage.percentage, 10)
        XCTAssertEqual(usage.model, "claude-opus-4-7")
        XCTAssertTrue(usage.isAutoCompactEnabled)
        XCTAssertEqual(usage.categories.count, 4)
        XCTAssertEqual(usage.categories[0].name, "Messages")
        XCTAssertEqual(usage.categories[0].tokens, 74_600)
        XCTAssertFalse(usage.categories[0].isDeferred)
    }

    func testParsesDeferredFlagAndDetailLists() throws {
        let usage = try decode([
            "categories": [
                ["name": "System tools (deferred)", "tokens": 19_157, "isDeferred": true],
                ["name": "MCP tools (deferred)", "tokens": 1_855, "isDeferred": true],
            ],
            "rawMaxTokens": 1_000_000,
            "memoryFiles": [
                ["path": "/Users/u/CLAUDE.md", "type": "Project", "tokens": 7_900],
                ["path": "~/.claude/CLAUDE.md", "tokens": 382],
            ],
            "mcpTools": [
                ["name": "browser__navigate", "serverName": "browser", "tokens": 320, "isLoaded": false]
            ],
            "agents": [
                ["agentType": "Explore", "source": "built-in", "tokens": 250]
            ],
            "isAutoCompactEnabled": false,
        ])
        XCTAssertTrue(usage.categories.allSatisfy(\.isDeferred))
        XCTAssertEqual(usage.memoryFiles.count, 2)
        XCTAssertEqual(usage.memoryFiles[0].path, "/Users/u/CLAUDE.md")
        XCTAssertEqual(usage.memoryFiles[0].type, "Project")
        XCTAssertEqual(usage.memoryFiles[0].tokens, 7_900)
        XCTAssertNil(usage.memoryFiles[1].type)
        XCTAssertEqual(usage.mcpTools.count, 1)
        XCTAssertEqual(usage.mcpTools[0].serverName, "browser")
        XCTAssertEqual(usage.mcpTools[0].isLoaded, false)
        XCTAssertEqual(usage.agents.count, 1)
        XCTAssertEqual(usage.agents[0].agentType, "Explore")
        XCTAssertFalse(usage.isAutoCompactEnabled)
    }

    func testToleratesMissingOptionalFields() throws {
        let usage = try decode(["rawMaxTokens": 200_000])
        XCTAssertEqual(usage.rawMaxTokens, 200_000)
        XCTAssertEqual(usage.totalTokens, 0)
        XCTAssertEqual(usage.percentage, 0)
        XCTAssertFalse(usage.isAutoCompactEnabled)
        XCTAssertTrue(usage.categories.isEmpty)
        XCTAssertTrue(usage.memoryFiles.isEmpty)
        XCTAssertNil(usage.model)
        XCTAssertNil(usage.apiUsage)
    }

    func testMalformedEntriesAreSkipped() throws {
        let usage = try decode([
            "categories": [["name": "Messages", "tokens": 5], ["tokens": "not a category"]],
            "rawMaxTokens": 10,
        ])
        XCTAssertEqual(usage.categories.map(\.name), ["Messages"])
    }

    private func decode(_ json: JSONValue) throws -> ContextUsage {
        try json.decode(ContextUsage.self)
    }
}
