import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// Review-only snapshot tests (opt-in; NOT a CI gate — the runner SKIPS
/// `*SnapshotTests.swift` on the unfiltered suite) for the AppKit `.mcp`
/// permission-card body. Renders the real `PermissionMcpCardBodyView` (built via
/// the production dispatch) so the headline + server chip + dimmed description +
/// capped JSON scroll parity can be eyeballed against the SwiftUI
/// `PermissionMcpCardBody` original. The CI gate is the non-snapshot
/// `PermissionMcpBodyTests`.
///
/// Run: `make test-unit FILTER=PermissionMcpBodySnapshotTests`, then open the
/// PNGs under `/tmp/ccterm-screenshots/`.
@MainActor
final class PermissionMcpBodySnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Wrap a bare NSView (pinned, padded, fixed width) in a throwaway VC over a
    /// window-tinted backdrop, mirroring the card's leading-aligned column.
    private func host(
        _ view: NSView, appearance: NSAppearance.Name, width: CGFloat = 460,
        padding: CGFloat = 14
    ) -> NSViewController {
        let root = NSView()
        root.wantsLayer = true
        root.appearance = NSAppearance(named: appearance)
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: padding),
            view.topAnchor.constraint(equalTo: root.topAnchor, constant: padding),
            view.bottomAnchor.constraint(
                lessThanOrEqualTo: root.bottomAnchor, constant: -padding),
            view.widthAnchor.constraint(equalToConstant: width),
        ])
        let vc = NSViewController()
        vc.view = root
        return vc
    }

    private func makeBody(toolName: String, input: [String: Any]) -> NSView {
        let req = PermissionRequest.makePreview(
            requestId: "mcp-preview", toolName: toolName, input: input)
        // Call the real conformer directly (the spine's same-named STUB coexists
        // pre-integration; the dispatch wiring is pinned by PermissionCardDispatchTests).
        return PermissionMcpCardBodyBuilder().makeBody(request: req, engine: nil)
    }

    private func attach(_ image: NSImage, _ name: String) {
        let url = ViewSnapshot.writePNG(image, name: name)
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testStandardServerToolSnapshot() throws {
        let body = makeBody(
            toolName: "mcp__linear__create_issue",
            input: [
                "description": "Create a Linear ticket from the failing test report.",
                "title": "Investigate CI flake on snapshot tests",
                "team": "ENG",
                "priority": 2,
            ])
        let vc = host(body, appearance: .aqua)
        let image = ViewSnapshot.renderViewController(vc, size: CGSize(width: 500, height: 320))
        attach(image, "PermissionMcpBody-standard")
        XCTAssertGreaterThanOrEqual(image.size.width, 460)
    }

    func testNestedToolNameSnapshot() throws {
        let body = makeBody(
            toolName: "mcp__chrome__tabs__create",
            input: ["url": "https://example.com", "active": true])
        let vc = host(body, appearance: .darkAqua)
        let image = ViewSnapshot.renderViewController(vc, size: CGSize(width: 500, height: 220))
        attach(image, "PermissionMcpBody-nested-dark")
        XCTAssertGreaterThanOrEqual(image.size.width, 460)
    }

    func testEmptyInputSnapshot() throws {
        let body = makeBody(toolName: "mcp__weather__current", input: [:])
        let vc = host(body, appearance: .aqua)
        let image = ViewSnapshot.renderViewController(vc, size: CGSize(width: 500, height: 120))
        attach(image, "PermissionMcpBody-empty")
        XCTAssertGreaterThanOrEqual(image.size.width, 460)
    }
}
