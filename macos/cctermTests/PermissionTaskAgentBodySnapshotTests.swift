import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// Review-only snapshot tests (opt-in; NOT the CI gate — the runner SKIPS
/// `*SnapshotTests.swift` on the unfiltered suite). Renders the AppKit
/// `.taskAgent` permission-card body (`PermissionTaskAgentCardBodyView`) so
/// parity against the SwiftUI `PermissionTaskAgentCardBody` can be eyeballed. The
/// real CI gate is the non-snapshot `PermissionTaskAgentBodyTests`.
///
/// Run: `make test-unit FILTER=PermissionTaskAgentBodySnapshotTests`, then open
/// the PNGs under `/tmp/ccterm-screenshots/`.
@MainActor
final class PermissionTaskAgentBodySnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Wrap a bare NSView (pinned, padded) in a throwaway VC over a window-tinted
    /// backdrop, for a given appearance. Mirrors `PermissionCardPiecesSnapshotTests.host`.
    private func host(
        _ view: NSView, appearance: NSAppearance.Name, width: CGFloat, padding: CGFloat = 14
    ) -> NSViewController {
        let root = NSView()
        root.wantsLayer = true
        root.appearance = NSAppearance(named: appearance)
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: padding),
            view.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -padding),
            view.topAnchor.constraint(equalTo: root.topAnchor, constant: padding),
            view.bottomAnchor.constraint(
                lessThanOrEqualTo: root.bottomAnchor, constant: -padding),
            view.widthAnchor.constraint(equalToConstant: width - 2 * padding),
        ])
        let vc = NSViewController()
        vc.view = root
        return vc
    }

    private func attach(_ image: NSImage, _ name: String) {
        let url = ViewSnapshot.writePNG(image, name: name)
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func body(_ input: [String: Any], tool: String = "Task") -> NSView {
        let req = PermissionRequest.makePreview(
            requestId: "snap-\(UUID().uuidString)", toolName: tool, input: input)
        return PermissionTaskAgentCardBodyBuilder().makeBody(request: req, engine: nil)
    }

    // MARK: - Explore agent · worktree + model + prompt (the full surface)

    func testFullTaskAgentBodySnapshot() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let view = body([
                "subagent_type": "Explore",
                "description": "Find permission card body sites",
                "prompt":
                    "Locate every file under macos/ccterm/Content/Chat/InputBarControls that "
                    + "defines a PermissionXxxCardBody view and report their paths.",
                "isolation": "worktree",
                "model": "sonnet",
            ])
            let vc = host(view, appearance: appearance, width: 520)
            let image = ViewSnapshot.renderViewController(
                vc, size: CGSize(width: 520, height: 260))
            attach(image, "PermissionTaskAgentBody-full-\(appearance == .aqua ? "light" : "dark")")
            XCTAssertGreaterThanOrEqual(image.size.width, 480)
        }
    }

    // MARK: - Generic sub-task · no chips, short prompt

    func testGenericSubTaskNoChipsSnapshot() throws {
        let view = body([
            "description": "Draft release notes",
            "prompt": "Summarise the last five merged PRs into a customer-facing release note.",
        ])
        let vc = host(view, appearance: .aqua, width: 520)
        let image = ViewSnapshot.renderViewController(vc, size: CGSize(width: 520, height: 180))
        attach(image, "PermissionTaskAgentBody-generic")
        XCTAssertGreaterThanOrEqual(image.size.width, 480)
    }

    // MARK: - Plan agent · model override only

    func testPlanAgentModelOverrideSnapshot() throws {
        let view = body(
            [
                "subagent_type": "Plan",
                "description": "Plan migration",
                "prompt": "Plan the migration from the old permission dialog to the new card.",
                "model": "opus",
            ], tool: "Agent")
        let vc = host(view, appearance: .aqua, width: 520)
        let image = ViewSnapshot.renderViewController(vc, size: CGSize(width: 520, height: 200))
        attach(image, "PermissionTaskAgentBody-plan-model")
        XCTAssertGreaterThanOrEqual(image.size.width, 480)
    }
}
