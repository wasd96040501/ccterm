import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// Review-only snapshot tests (opt-in; NOT a CI gate — the runner SKIPS
/// `*SnapshotTests.swift` on the unfiltered suite) for the AppKit `.exitPlanMode`
/// permission-card body. Renders the real `PermissionExitPlanModeCardBodyView`
/// (built via the production `PermissionExitPlanModeCardBodyBuilder`) so
/// the headline + 480pt-cap monospace plan scroll / file-backed hint parity can
/// be eyeballed against the SwiftUI `PermissionExitPlanModeCardBody` original.
/// The CI gate is the non-snapshot `PermissionExitPlanModeBodyTests`.
///
/// Run: `make test-unit FILTER=PermissionExitPlanModeBodySnapshotTests`, then open
/// the PNGs under `/tmp/ccterm-screenshots/`.
@MainActor
final class PermissionExitPlanModeBodySnapshotTests: XCTestCase {

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
            requestId: "exit-preview", toolName: toolName, input: input)
        return PermissionExitPlanModeCardBodyBuilder().makeBody(request: req, engine: nil)
    }

    private func attach(_ image: NSImage, _ name: String) {
        let url = ViewSnapshot.writePNG(image, name: name)
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testV1PlanSnapshot() throws {
        let body = makeBody(
            toolName: "ExitPlanMode",
            input: [
                "plan": """
                ## Refactor permission cards

                1. Extract per-kind body views into their own files.
                2. Add a body builder for each kind.
                3. Wire the dispatch into the AppKit card.
                4. Cover the new bodies with unit tests.

                ## Risks

                - Snapshot diffs may shift; re-bless after review.
                - Localisation keys need translation updates.
                """
            ])
        let vc = host(body, appearance: .aqua)
        let image = ViewSnapshot.renderViewController(vc, size: CGSize(width: 500, height: 360))
        attach(image, "PermissionExitPlanModeBody-v1-plan")
        XCTAssertGreaterThanOrEqual(image.size.width, 460)
    }

    func testV1PlanDarkSnapshot() throws {
        let body = makeBody(
            toolName: "ExitPlanMode",
            input: ["plan": "1. Refactor auth\n2. Add tests\n3. Ship behind a flag"])
        let vc = host(body, appearance: .darkAqua)
        let image = ViewSnapshot.renderViewController(vc, size: CGSize(width: 500, height: 220))
        attach(image, "PermissionExitPlanModeBody-v1-plan-dark")
        XCTAssertGreaterThanOrEqual(image.size.width, 460)
    }

    func testV2FileBackedHintSnapshot() throws {
        let body = makeBody(toolName: "ExitPlanModeV2", input: [:])
        let vc = host(body, appearance: .aqua)
        let image = ViewSnapshot.renderViewController(vc, size: CGSize(width: 500, height: 120))
        attach(image, "PermissionExitPlanModeBody-v2-hint")
        XCTAssertGreaterThanOrEqual(image.size.width, 460)
    }

    func testV1EmptyPlanHintSnapshot() throws {
        let body = makeBody(toolName: "ExitPlanMode", input: [:])
        let vc = host(body, appearance: .aqua)
        let image = ViewSnapshot.renderViewController(vc, size: CGSize(width: 500, height: 120))
        attach(image, "PermissionExitPlanModeBody-empty-plan")
        XCTAssertGreaterThanOrEqual(image.size.width, 460)
    }
}
