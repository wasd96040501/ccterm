import AgentSDK
import AppKit
import Foundation
import XCTest

@testable import ccterm

/// CI-gate measurement test (non-snapshot) for the AppKit `.mcp` permission-card
/// body (migration plan §4.4, §9). Drives the REAL body builder
/// (`PermissionMcpCardBodyBuilder.makeBody`) the dispatch returns for `.mcp`,
/// mounts the produced `NSView`, and asserts the parsed `mcp__server__tool`
/// triple + description + JSON actually render into the production subviews —
/// no re-implemented approximation, no test-only seam.
///
/// Distinct from `PermissionMcpCardBodyTests` (which exercises the surviving
/// SwiftUI `PermissionMcpCardBody` struct this phase): this class drives the
/// AppKit replacement through `PermissionCardBodyBuilding`.
@MainActor
final class PermissionMcpBodyTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    private func request(
        toolName: String, input: [String: Any]
    ) -> PermissionRequest {
        PermissionRequest.makePreview(
            requestId: "mcp-\(UUID().uuidString)", toolName: toolName, input: input)
    }

    /// Build the body through the REAL production conformer
    /// (`PermissionMcpCardBodyBuilder.makeBody`, the same instance the dispatch
    /// returns for `.mcp`) and downcast to the concrete view so the test can read
    /// the rendered subviews. We call the conformer directly (not via
    /// `permissionCardBodyBuilder(for:)`) — matching the sibling body tests —
    /// because the spine's same-named STUB still coexists pre-integration; the
    /// `.mcp` → builder dispatch wiring is pinned separately by
    /// `PermissionCardDispatchTests`. We also assert the `.mcp` kind resolves so
    /// the routing contract this body relies on is still covered here.
    private func makeMountedBody(
        toolName: String, input: [String: Any], width: CGFloat = 460
    ) -> (PermissionMcpCardBodyView, NSWindow) {
        let req = request(toolName: toolName, input: input)
        XCTAssertEqual(
            PermissionCardKind.kind(for: req), .mcp,
            "An `mcp__*` request must resolve to the .mcp kind so the dispatch routes here.")
        let view = PermissionMcpCardBodyBuilder().makeBody(request: req, engine: nil)
        guard let body = view as? PermissionMcpCardBodyView else {
            XCTFail("PermissionMcpCardBodyBuilder must build a PermissionMcpCardBodyView.")
            return (PermissionMcpCardBodyView(request: req), NSWindow())
        }

        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: width, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        window.contentView = container
        window.ccterm_orderFrontForTesting()
        body.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            body.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        container.layoutSubtreeIfNeeded()
        body.layoutSubtreeIfNeeded()
        return (body, window)
    }

    private func close(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }

    private func text(of field: NSTextField?) -> String? { field?.stringValue }

    // MARK: - Headline: tool name + server chip render the parsed triple

    func testHeadlineRendersParsedServerAndTool() {
        let (body, window) = makeMountedBody(
            toolName: "mcp__linear__create_issue", input: [:])
        defer { close(window) }

        XCTAssertEqual(
            text(of: body.toolNameLabel), "create_issue",
            "The headline label shows the parsed tool segment, not the raw mcp__ name.")
        XCTAssertEqual(
            body.serverChip?.text, "linear",
            "The rounded-pill server chip shows the parsed server (trust boundary).")
    }

    func testNestedToolNameKeepsDoubleUnderscoreSegment() {
        // `mcp__server__a__b` → server `linear`, tool `issue__create` (everything
        // after the first __ pair). Verbatim getter behaviour, rendered.
        let (body, window) = makeMountedBody(
            toolName: "mcp__linear__issue__create", input: [:])
        defer { close(window) }
        XCTAssertEqual(text(of: body.toolNameLabel), "issue__create")
        XCTAssertEqual(body.serverChip?.text, "linear")
    }

    func testServerOnlyNameRendersServerAsBothPieces() {
        // Malformed name with only a server segment must not blank the headline.
        let (body, window) = makeMountedBody(toolName: "mcp__lonely", input: [:])
        defer { close(window) }
        XCTAssertEqual(text(of: body.toolNameLabel), "lonely")
        XCTAssertEqual(body.serverChip?.text, "lonely")
    }

    // MARK: - Description: dimmed, rendered only when supplied

    func testDescriptionRendersWhenSupplied() {
        let (body, window) = makeMountedBody(
            toolName: "mcp__github__create_issue",
            input: ["description": "open a bug ticket"])
        defer { close(window) }
        XCTAssertEqual(
            text(of: body.descriptionLabel), "open a bug ticket",
            "A non-empty description renders into the dimmed label.")
        XCTAssertEqual(
            body.descriptionLabel?.textColor, .secondaryLabelColor,
            "Description is dimmed (SwiftUI `.secondary` → secondaryLabelColor).")
        XCTAssertEqual(
            body.descriptionLabel?.maximumNumberOfLines,
            PermissionMcpCardBodyBuilder.descriptionLineLimit,
            "Description caps at 3 lines (PermissionMcpCardBody.swift:37).")
    }

    func testNoDescriptionMeansNoDescriptionLabel() {
        let (body, window) = makeMountedBody(
            toolName: "mcp__github__list", input: ["limit": 5])
        defer { close(window) }
        XCTAssertNil(
            body.descriptionLabel,
            "With no `description` key, the dimmed description row is absent.")
    }

    func testEmptyDescriptionIsTreatedAsAbsent() {
        let (body, window) = makeMountedBody(
            toolName: "mcp__github__list", input: ["description": ""])
        defer { close(window) }
        XCTAssertNil(
            body.descriptionLabel,
            "An empty-string description collapses the row (raw?.isEmpty == false guard).")
    }

    // MARK: - JSON block: pretty-printed, sorted, capped, present only when non-empty

    func testInputJSONBlockRendersPrettyPrintedSortedKeys() {
        let (body, window) = makeMountedBody(
            toolName: "mcp__github__create_issue",
            input: ["title": "Bug", "body": "details"])
        defer { close(window) }

        // The block must exist and carry the 200pt cap.
        let block = try? XCTUnwrap(body.jsonBlock)
        XCTAssertNotNil(block, "A non-empty rawInput renders the JSON monospace block.")
        XCTAssertEqual(
            block?.maxHeight, PermissionMcpCardBodyBuilder.jsonMaxHeight,
            "MCP JSON block caps at 200pt (PermissionMcpCardBody.swift:48).")
        XCTAssertEqual(block?.maxHeight ?? -1, 200, accuracy: 0.5)

        // The serialised content (read from the same getter the body renders) is
        // pretty-printed (newlines) with sorted keys (body before title).
        let json = try? XCTUnwrap(body.request.mcpInputJSON)
        guard let json = json else { return }
        XCTAssertTrue(json.contains("\n"), "Pretty-printed JSON inserts newlines.")
        let bodyIdx = json.range(of: "\"body\"")?.lowerBound
        let titleIdx = json.range(of: "\"title\"")?.lowerBound
        XCTAssertNotNil(bodyIdx)
        XCTAssertNotNil(titleIdx)
        if let bodyIdx, let titleIdx {
            XCTAssertLessThan(bodyIdx, titleIdx, "sortedKeys → \"body\" before \"title\".")
        }
    }

    func testEmptyInputMeansNoJSONBlock() {
        let (body, window) = makeMountedBody(toolName: "mcp__github__list", input: [:])
        defer { close(window) }
        XCTAssertNil(
            body.jsonBlock,
            "Empty rawInput → inputJSON nil → the JSON block is absent.")
    }

    // MARK: - Row composition (the 4 SwiftUI branches, against the real stack)

    func testRowCompositionFullCard() {
        // server + tool + description + JSON → headline, description, json (3 rows).
        let (body, window) = makeMountedBody(
            toolName: "mcp__linear__create_issue",
            input: ["description": "ticket", "team": "ENG"])
        defer { close(window) }
        XCTAssertEqual(
            body.arrangedSubviews.count, 3,
            "Full card = headline + description + JSON block.")
        XCTAssertNotNil(body.serverChip)
        XCTAssertNotNil(body.descriptionLabel)
        XCTAssertNotNil(body.jsonBlock)
    }

    func testRowCompositionHeadlineOnly() {
        // No description, empty input → only the headline row.
        let (body, window) = makeMountedBody(toolName: "mcp__weather__current", input: [:])
        defer { close(window) }
        XCTAssertEqual(
            body.arrangedSubviews.count, 1,
            "No description + empty input collapses to the headline row only.")
        XCTAssertNil(body.descriptionLabel)
        XCTAssertNil(body.jsonBlock)
    }

    // MARK: - Verbatim data getters (parsing parity with the SwiftUI source)

    func testGettersParseTripleLikeSwiftUISource() {
        let req = request(toolName: "mcp__github__create_issue", input: [:])
        XCTAssertEqual(req.mcpServerName, "github")
        XCTAssertEqual(req.mcpToolName, "create_issue")
        XCTAssertEqual(req.mcpToolDisplayName, "create_issue")
    }

    func testGetterNonMcpNameProducesNilComponents() {
        // The parser must not swallow non-MCP names — a direct caller gets nil so
        // the display name falls back to the literal tool name.
        let req = request(toolName: "Bash", input: [:])
        XCTAssertNil(req.mcpComponents)
        XCTAssertEqual(req.mcpToolDisplayName, "Bash")
    }

    func testGetterEmptyInputProducesNilJSON() {
        let req = request(toolName: "mcp__github__list", input: [:])
        XCTAssertNil(req.mcpInputJSON)
    }
}
