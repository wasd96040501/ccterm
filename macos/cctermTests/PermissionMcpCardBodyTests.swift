import AgentSDK
import Foundation
import XCTest

@testable import ccterm

/// Logic tests for the MCP body's tool-name parsing
/// (`mcp__<server>__<tool>` triple) and JSON serialisation of the
/// raw input. The chip surface is small but stable shape — pin it
/// here so future tweaks to the routing layer don't silently break
/// the server-vs-tool split.
final class PermissionMcpCardBodyTests: XCTestCase {

    func testParsesServerAndToolFromTriple() {
        let body = makeBody(toolName: "mcp__github__create_issue", input: [:])
        XCTAssertEqual(body.serverName, "github")
        XCTAssertEqual(body.toolName, "create_issue")
        XCTAssertEqual(body.toolDisplayName, "create_issue")
    }

    func testToolNameSegmentsCanContainDoubleUnderscore() {
        // The convention is "everything after the first __ pair is
        // the tool" — so `mcp__server__a__b` keeps `a__b` intact as
        // the tool identity. Without this branch the user would see
        // a truncated display name.
        let body = makeBody(
            toolName: "mcp__linear__issue__create", input: [:])
        XCTAssertEqual(body.serverName, "linear")
        XCTAssertEqual(body.toolName, "issue__create")
    }

    func testServerOnlyFallsBackGracefully() {
        // Defensive — a malformed name with only a server segment
        // shouldn't blank out the headline. Use the server as both
        // pieces so the user at least knows which MCP is calling.
        let body = makeBody(toolName: "mcp__lonely", input: [:])
        XCTAssertEqual(body.serverName, "lonely")
        XCTAssertEqual(body.toolName, "lonely")
    }

    func testNonMcpToolNameProducesNilComponents() {
        // Sanity check — the parser shouldn't accidentally swallow
        // non-MCP names. `kind(for:)` only routes mcp__ here, but a
        // direct caller (e.g. a future preview) should get nil so
        // the headline falls back to the literal name.
        let body = makeBody(toolName: "Bash", input: [:])
        XCTAssertNil(body.components)
        XCTAssertEqual(body.toolDisplayName, "Bash")
    }

    func testDescriptionIsExposed() {
        let body = makeBody(
            toolName: "mcp__github__create_issue",
            input: ["description": "open a bug ticket"])
        XCTAssertEqual(body.description, "open a bug ticket")
    }

    func testInputJSONIsPrettyPrintedAndSorted() {
        let body = makeBody(
            toolName: "mcp__github__create_issue",
            input: ["title": "Bug", "body": "details"])
        let json = body.inputJSON
        XCTAssertNotNil(json)
        // sortedKeys -> "body" appears before "title", and pretty
        // printing inserts newlines + two-space indent.
        guard let json else { return }
        let bodyIdx = json.range(of: "\"body\"")?.lowerBound
        let titleIdx = json.range(of: "\"title\"")?.lowerBound
        XCTAssertNotNil(bodyIdx)
        XCTAssertNotNil(titleIdx)
        if let bodyIdx, let titleIdx {
            XCTAssertLessThan(bodyIdx, titleIdx)
        }
        XCTAssertTrue(json.contains("\n"))
    }

    func testEmptyInputProducesNilJSON() {
        let body = makeBody(toolName: "mcp__github__list", input: [:])
        XCTAssertNil(body.inputJSON)
    }

    // MARK: - Helpers

    private func makeBody(
        toolName: String, input: [String: Any]
    )
        -> PermissionMcpCardBody
    {
        let req = PermissionRequest.makePreview(
            requestId: "mcp-\(UUID().uuidString)",
            toolName: toolName,
            input: input)
        return PermissionMcpCardBody(request: req)
    }
}
