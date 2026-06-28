import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// Visual-parity snapshot (review-only, opt-in; SKIPPED on the default suite).
/// Renders the AppKit `PermissionFilesystemReadCardBodyView` for Read / Glob /
/// Grep so the per-tool layout can be eyeballed against the original SwiftUI
/// `PermissionFilesystemReadCardBody`. Not a CI gate — the non-snapshot
/// `PermissionFilesystemReadBodyTests` is the regression gate.
///
/// Run: `make test-unit FILTER=PermissionFilesystemReadBodySnapshotTests`
/// PNG:  /tmp/ccterm-screenshots/PermissionFilesystemReadBody-*.png
@MainActor
final class PermissionFilesystemReadBodySnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func snapshot(name: String, toolName: String, input: [String: Any]) {
        let request = PermissionRequest.makePreview(
            requestId: "snap-\(name)",
            toolName: toolName,
            input: input)
        let body = PermissionFilesystemReadCardBodyView(request: request)

        // Host the bare NSView in a throwaway VC (the §9 wrap-a-bare-NSView
        // pattern). 14pt padding on a windowBackground card, 520pt wide to match
        // the original body's #Preview frame.
        let card = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 100))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        body.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            body.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            body.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
        ])

        let vc = NSViewController()
        vc.view = card

        let image = ViewSnapshot.renderViewController(
            vc, size: CGSize(width: 520, height: 100))
        let url = ViewSnapshot.writePNG(image, name: "PermissionFilesystemReadBody-\(name)")

        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "PermissionFilesystemReadBody-\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertGreaterThanOrEqual(image.size.width, 500)
    }

    func testRead() {
        snapshot(
            name: "Read", toolName: "Read",
            input: ["file_path": "/Users/example/Project/Sources/Greeter.swift"])
    }

    func testGlob() {
        snapshot(
            name: "Glob", toolName: "Glob",
            input: ["pattern": "**/*.swift", "path": "/Users/example/Project/Sources"])
    }

    func testGrep() {
        snapshot(
            name: "Grep", toolName: "Grep",
            input: [
                "pattern": "TODO|FIXME",
                "path": "/Users/example/Project",
                "output_mode": "files_with_matches",
            ])
    }
}
