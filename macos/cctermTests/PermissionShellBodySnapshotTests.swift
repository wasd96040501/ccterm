import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// Review-only snapshot tests (opt-in; NOT a CI gate — the runner SKIPS
/// `*SnapshotTests.swift` on the unfiltered suite) for the AppKit `.bash` /
/// `.powerShell` permission-card body. Renders the real
/// `PermissionShellCardBodyView` so the command code-block + dimmed description +
/// compound-command hint parity can be eyeballed against the SwiftUI
/// `PermissionShellCardBody` original. The CI gate is the non-snapshot
/// `PermissionShellBodyTests`.
///
/// Constructs the production body view directly (rather than through
/// `permissionCardBodyBuilder(for:)`), so the snapshot renders the REAL body even
/// before the integration step swaps the dispatch's STUB for the real builder.
///
/// Run: `make test-unit FILTER=PermissionShellBodySnapshotTests`, then open the
/// PNGs under `/tmp/ccterm-screenshots/`.
@MainActor
final class PermissionShellBodySnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Wrap a bare NSView (pinned, padded, fixed width) in a throwaway VC over a
    /// window-tinted backdrop, mirroring the card's leading-aligned column
    /// (padding 14 = `PermissionCardContentView.horizontalPadding`).
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

    private func body(
        toolName: String, kind: PermissionCardKind, input: [String: Any]
    )
        -> PermissionShellCardBodyView
    {
        let req = PermissionRequest.makePreview(
            requestId: "shell-preview", toolName: toolName, input: input)
        return PermissionShellCardBodyView(request: req, kind: kind, engine: nil)
    }

    private func attach(_ image: NSImage, _ name: String) {
        let url = ViewSnapshot.writePNG(image, name: name)
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSimpleBashCommandSnapshot() throws {
        let view = body(
            toolName: "Bash", kind: .bash,
            input: ["command": "rm -rf node_modules", "description": "Reset deps"])
        let vc = host(view, appearance: .aqua)
        let image = ViewSnapshot.renderViewController(vc, size: CGSize(width: 500, height: 200))
        attach(image, "PermissionShellBody-simple")
        XCTAssertGreaterThanOrEqual(image.size.width, 460)
    }

    func testMultilineHeredocSnapshot() throws {
        let view = body(
            toolName: "Bash", kind: .bash,
            input: [
                "command":
                    "git commit -m \"$(cat <<'EOF'\nfeat: add preview\n\nLong body explaining the change in detail.\nEOF\n)\"",
                "description": "Commit current changes",
            ])
        let vc = host(view, appearance: .darkAqua)
        let image = ViewSnapshot.renderViewController(vc, size: CGSize(width: 500, height: 280))
        attach(image, "PermissionShellBody-heredoc-dark")
        XCTAssertGreaterThanOrEqual(image.size.width, 460)
    }

    func testCompoundHintSnapshot() throws {
        // subcommandResults + multiple bash rules → the compound hint row renders.
        let req = try! PermissionRequest(json: [
            "request_id": "shell-preview-compound",
            "tool_name": "Bash",
            "input": ["command": "cd src && git status && npm test"],
            "decision_reason": ["type": "subcommandResults"],
            "permission_suggestions": [
                [
                    "type": "addRules",
                    "rules": [
                        ["tool_name": "Bash", "rule_content": "git status:*"],
                        ["tool_name": "Bash", "rule_content": "npm test:*"],
                        ["tool_name": "Bash", "rule_content": "cd:*"],
                    ],
                    "behavior": "allow",
                    "destination": "localSettings",
                ]
            ],
        ])
        let view = PermissionShellCardBodyView(request: req, kind: .bash, engine: nil)
        let vc = host(view, appearance: .aqua)
        let image = ViewSnapshot.renderViewController(vc, size: CGSize(width: 500, height: 200))
        attach(image, "PermissionShellBody-compound-hint")
        XCTAssertGreaterThanOrEqual(image.size.width, 460)
    }

    func testPowerShellCommandSnapshot() throws {
        let view = body(
            toolName: "PowerShell", kind: .powerShell,
            input: [
                "command": "Get-ChildItem -Recurse -Filter *.swift | Measure-Object",
                "description": "Count Swift files",
            ])
        let vc = host(view, appearance: .aqua)
        let image = ViewSnapshot.renderViewController(vc, size: CGSize(width: 500, height: 200))
        attach(image, "PermissionShellBody-powershell")
        XCTAssertGreaterThanOrEqual(image.size.width, 460)
    }
}
