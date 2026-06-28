import AgentSDK
import AppKit
import Foundation
import XCTest

@testable import ccterm

/// CI-gate measurement test (non-snapshot) for the AppKit `.webFetch`
/// permission-card body (migration plan §4.4, §9). Drives the REAL body builder
/// (`PermissionWebFetchCardBodyBuilder.makeBody`) the dispatch returns for
/// `.webFetch`, mounts the produced `NSView`, and asserts the parsed `url` +
/// domain chip + `prompt` actually render into the production subviews — no
/// re-implemented approximation, no test-only seam.
///
/// Distinct from `PermissionWebFetchCardBodyTests` (which exercises the
/// surviving SwiftUI `PermissionWebFetchCardBody` struct this phase): this class
/// drives the AppKit replacement through `PermissionCardBodyBuilding`.
@MainActor
final class PermissionWebFetchBodyTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    private func request(input: [String: Any]) -> PermissionRequest {
        PermissionRequest.makePreview(
            requestId: "wf-\(UUID().uuidString)", toolName: "WebFetch", input: input)
    }

    /// Build the body the production way — through the dispatch (`.webFetch` →
    /// `PermissionWebFetchCardBodyBuilder`) — and downcast to the concrete view
    /// so the test can read the rendered subviews. The downcast is itself an
    /// assertion: the dispatch must hand back this body for a `WebFetch` request.
    private func makeMountedBody(
        input: [String: Any], width: CGFloat = 460
    ) -> (PermissionWebFetchCardBodyView, NSWindow) {
        let req = request(input: input)
        // Route through the real kind resolver + dispatch (not a direct ctor) so
        // the test pins the `.webFetch` → builder wiring as well.
        XCTAssertEqual(
            PermissionCardKind.kind(for: req), .webFetch,
            "A `WebFetch` request must resolve to the .webFetch kind so the dispatch routes here.")
        let builder = permissionCardBodyBuilder(for: .webFetch)
        let view = builder.makeBody(request: req, engine: nil)
        guard let body = view as? PermissionWebFetchCardBodyView else {
            XCTFail("Dispatch must build a PermissionWebFetchCardBodyView for .webFetch.")
            return (PermissionWebFetchCardBodyView(request: req), NSWindow())
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

    // MARK: - URL line renders the request URL

    func testURLRendersIntoMonospaceLine() {
        let (body, window) = makeMountedBody(input: [
            "url": "https://docs.anthropic.com/en/api/overview",
            "prompt": "Summarize the rate-limit section",
        ])
        defer { close(window) }

        XCTAssertEqual(
            body.renderedURLText, "https://docs.anthropic.com/en/api/overview",
            "The prominent URL line shows the request's `url` verbatim.")
    }

    func testMissingURLShowsDashPlaceholder() {
        let (body, window) = makeMountedBody(input: [:])
        defer { close(window) }

        XCTAssertEqual(
            body.renderedURLText, PermissionWebFetchCardBodyBuilder.missingURLPlaceholder,
            "With no `url`, the line falls back to the `\"—\"` placeholder (parity with SwiftUI `url ?? \"—\"`).")
        XCTAssertNil(body.domainChipLabel, "No URL ⇒ no host ⇒ no domain chip.")
        XCTAssertNil(body.promptLabel, "No prompt key ⇒ no prompt row.")
    }

    func testEmptyURLIsTreatedAsMissing() {
        let (body, window) = makeMountedBody(input: ["url": ""])
        defer { close(window) }
        XCTAssertEqual(
            body.renderedURLText, PermissionWebFetchCardBodyBuilder.missingURLPlaceholder,
            "An empty-string URL collapses to the placeholder (raw?.isEmpty == false guard).")
    }

    // MARK: - Domain chip renders the parsed host

    func testDomainChipRendersParsedHostname() {
        let (body, window) = makeMountedBody(input: [
            "url": "https://api.example.com:8443/v2/users?since=1"
        ])
        defer { close(window) }

        XCTAssertEqual(
            body.domainChipLabel?.stringValue, "api.example.com",
            "The domain chip shows the bare host (path/port/query stripped) for pattern-matching.")
        XCTAssertEqual(
            body.domainChipLabel?.textColor, .secondaryLabelColor,
            "The domain chip is dimmed (SwiftUI `.secondary` → secondaryLabelColor).")
    }

    func testMalformedURLHidesDomainChipButKeepsURL() {
        // "not a real url" doesn't parse to a host — the chip is hidden but the
        // raw URL still renders so the user sees what was requested.
        let (body, window) = makeMountedBody(input: ["url": "not a real url"])
        defer { close(window) }

        XCTAssertEqual(body.renderedURLText, "not a real url")
        XCTAssertNil(
            body.domainChipLabel,
            "A URL with no parseable host hides the domain chip (hostname == nil).")
    }

    // MARK: - Prompt renders dimmed, only when supplied

    func testPromptRendersDimmedWhenSupplied() {
        let (body, window) = makeMountedBody(input: [
            "url": "https://example.com/release-notes",
            "prompt": "Summarise the section on optionals and protocol extensions.",
        ])
        defer { close(window) }

        XCTAssertEqual(
            body.promptLabel?.stringValue,
            "Summarise the section on optionals and protocol extensions.",
            "A non-empty prompt renders into the dimmed secondary label.")
        XCTAssertEqual(
            body.promptLabel?.textColor, .secondaryLabelColor,
            "Prompt is dimmed (SwiftUI `.secondary` → secondaryLabelColor).")
        XCTAssertEqual(
            body.promptLabel?.maximumNumberOfLines,
            PermissionWebFetchCardBodyBuilder.promptLineLimit,
            "Prompt caps at 3 lines (PermissionWebFetchCardBody.swift:41).")
    }

    func testEmptyPromptIsTreatedAsAbsent() {
        let (body, window) = makeMountedBody(input: [
            "url": "https://example.com",
            "prompt": "",
        ])
        defer { close(window) }
        XCTAssertNil(
            body.promptLabel,
            "An empty-string prompt collapses the row (raw?.isEmpty == false guard).")
    }

    // MARK: - Row composition (the data branches, against the real stack)

    func testRowCompositionFullBody() {
        // url (with host) + prompt → url line, domain chip, prompt (3 rows).
        let (body, window) = makeMountedBody(input: [
            "url": "https://docs.swift.org/swift-book/",
            "prompt": "Summarise the optionals chapter.",
        ])
        defer { close(window) }
        XCTAssertEqual(
            body.arrangedSubviews.count, 3,
            "Full body = URL line + domain chip + prompt.")
        XCTAssertNotNil(body.domainChipLabel)
        XCTAssertNotNil(body.promptLabel)
    }

    func testRowCompositionURLOnly() {
        // host parses, no prompt → URL line + domain chip (2 rows).
        let (body, window) = makeMountedBody(input: ["url": "https://example.com/x"])
        defer { close(window) }
        XCTAssertEqual(
            body.arrangedSubviews.count, 2,
            "URL with host and no prompt → URL line + domain chip.")
        XCTAssertNotNil(body.domainChipLabel)
        XCTAssertNil(body.promptLabel)
    }

    func testRowCompositionURLLineOnlyWhenHostUnparseable() {
        // malformed URL, no prompt → only the URL line.
        let (body, window) = makeMountedBody(input: ["url": "not a real url"])
        defer { close(window) }
        XCTAssertEqual(
            body.arrangedSubviews.count, 1,
            "Unparseable host + no prompt collapses to the URL line only.")
    }

    // MARK: - Verbatim data getters (parsing parity with the SwiftUI source)

    func testGettersParseLikeSwiftUISource() {
        let req = request(input: [
            "url": "https://api.example.com:8443/v2/users?since=1",
            "prompt": "Summarize the rate-limit section",
        ])
        XCTAssertEqual(req.webFetchURL, "https://api.example.com:8443/v2/users?since=1")
        XCTAssertEqual(req.webFetchHostname, "api.example.com")
        XCTAssertEqual(req.webFetchPrompt, "Summarize the rate-limit section")
    }

    func testGetterEmptyURLIsNil() {
        XCTAssertNil(request(input: ["url": ""]).webFetchURL)
        XCTAssertNil(request(input: ["url": ""]).webFetchHostname)
    }

    func testGetterMalformedURLProducesNilHostname() {
        let req = request(input: ["url": "not a real url"])
        XCTAssertEqual(req.webFetchURL, "not a real url")
        XCTAssertNil(req.webFetchHostname)
    }
}
