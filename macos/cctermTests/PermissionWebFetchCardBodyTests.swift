import AgentSDK
import XCTest

@testable import ccterm

/// Logic tests for the WebFetch body's data extraction: `url`,
/// parsed `hostname`, and the `prompt` (the question Claude wants
/// answered about the fetched content).
final class PermissionWebFetchCardBodyTests: XCTestCase {

    func testUrlAndHostnameAreParsed() {
        let body = makeBody(input: [
            "url": "https://docs.anthropic.com/en/api/overview",
            "prompt": "Summarize the rate-limit section",
        ])
        XCTAssertEqual(body.url, "https://docs.anthropic.com/en/api/overview")
        XCTAssertEqual(body.hostname, "docs.anthropic.com")
        XCTAssertEqual(body.prompt, "Summarize the rate-limit section")
    }

    func testHostnameNilForMalformedUrl() {
        // "not a real url" doesn't parse — the chip is hidden but
        // the raw `url` still renders so the user sees what was
        // requested.
        let body = makeBody(input: ["url": "not a real url"])
        XCTAssertEqual(body.url, "not a real url")
        XCTAssertNil(body.hostname)
    }

    func testEmptyUrlIsTreatedAsNil() {
        let body = makeBody(input: ["url": ""])
        XCTAssertNil(body.url)
        XCTAssertNil(body.hostname)
    }

    func testEmptyPromptIsTreatedAsNil() {
        let body = makeBody(input: [
            "url": "https://example.com",
            "prompt": "",
        ])
        XCTAssertNil(body.prompt)
    }

    func testHostnameStripsPathAndQuery() {
        // URLs with path / query / port should still resolve to the
        // bare hostname for the chip — same shape the upstream Bash
        // rule uses (`domain:<host>`).
        let body = makeBody(input: [
            "url": "https://api.example.com:8443/v2/users?since=1"
        ])
        XCTAssertEqual(body.hostname, "api.example.com")
    }

    // MARK: - Helpers

    private func makeBody(input: [String: Any]) -> PermissionWebFetchCardBody {
        let req = PermissionRequest.makePreview(
            requestId: "wf-\(UUID().uuidString)",
            toolName: "WebFetch",
            input: input)
        return PermissionWebFetchCardBody(request: req)
    }
}
