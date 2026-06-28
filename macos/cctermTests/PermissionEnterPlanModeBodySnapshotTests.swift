import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// Review-only snapshot tests (opt-in; NOT the CI gate — the runner SKIPS
/// `*SnapshotTests.swift` on the unfiltered suite). Renders the AppKit
/// `.enterPlanMode` permission-card body (`PermissionEnterPlanModeCardBodyView`)
/// so parity against the SwiftUI `PermissionEnterPlanModeCardBody` can be
/// eyeballed (icon tint, bullet indentation, secondary-text dimming). The real CI
/// gate is the non-snapshot `PermissionEnterPlanModeBodyTests`.
///
/// Run: `make test-unit FILTER=PermissionEnterPlanModeBodySnapshotTests`, then
/// open the PNGs under `/tmp/ccterm-screenshots/`.
@MainActor
final class PermissionEnterPlanModeBodySnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Wrap a bare NSView (pinned, padded) in a throwaway VC over a window-tinted
    /// backdrop, for a given appearance. Mirrors
    /// `PermissionTaskAgentBodySnapshotTests.host`.
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

    private func body(tool: String = "EnterPlanMode") -> NSView {
        let req = PermissionRequest.makePreview(
            requestId: "snap-\(UUID().uuidString)", toolName: tool, input: [:])
        return PermissionEnterPlanModeCardBodyBuilder().makeBody(request: req, engine: nil)
    }

    // MARK: - Full body, both appearances

    func testEnterPlanModeBodySnapshot() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let view = body()
            let vc = host(view, appearance: appearance, width: 520)
            let image = ViewSnapshot.renderViewController(
                vc, size: CGSize(width: 520, height: 200))
            attach(image, "PermissionEnterPlanModeBody-\(appearance == .aqua ? "light" : "dark")")
            XCTAssertGreaterThanOrEqual(image.size.width, 480)
        }
    }
}
