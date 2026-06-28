import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// Review-only snapshot test (opt-in; NOT the CI gate — the runner SKIPS
/// `*SnapshotTests.swift` on the unfiltered suite) for the AppKit Skill
/// permission card body. Renders the three representative states so parity with
/// the SwiftUI `PermissionSkillCardBody` can be eyeballed. The real CI gate is
/// the non-snapshot `PermissionSkillBodyTests`.
///
/// Run: `make test-unit FILTER=PermissionSkillBodySnapshotTests`, then open the
/// PNGs under `/tmp/ccterm-screenshots/`.
@MainActor
final class PermissionSkillBodySnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Wrap the body (pinned to a card-column width, padded) in a throwaway VC
    /// over a window-tinted backdrop, mirroring the 14pt card padding + 520
    /// preview width used by the SwiftUI `#Preview`s.
    private func host(_ body: NSView, appearance: NSAppearance.Name) -> NSViewController {
        let root = NSView()
        root.wantsLayer = true
        root.appearance = NSAppearance(named: appearance)
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        body.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            body.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
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

    private func body(_ input: [String: Any]) -> PermissionSkillCardBodyView {
        let req = PermissionRequest.makePreview(
            requestId: "skill-snap-\(UUID().uuidString)", toolName: "Skill", input: input)
        return PermissionSkillCardBodyView(request: req)
    }

    func testSkillWithArgs() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let vc = host(
                body(["skill": "review", "args": "--scope diff"]), appearance: appearance)
            let image = ViewSnapshot.renderViewController(vc, size: CGSize(width: 520, height: 120))
            attach(image, "PermissionSkillBody-withArgs-\(appearance == .aqua ? "light" : "dark")")
            XCTAssertGreaterThanOrEqual(image.size.width, 480)
        }
    }

    func testSkillNoArgs() throws {
        let vc = host(body(["skill": "commit"]), appearance: .aqua)
        let image = ViewSnapshot.renderViewController(vc, size: CGSize(width: 520, height: 100))
        attach(image, "PermissionSkillBody-noArgs")
        XCTAssertGreaterThanOrEqual(image.size.width, 480)
    }

    func testSkillMissingName() throws {
        let vc = host(body([:]), appearance: .aqua)
        let image = ViewSnapshot.renderViewController(vc, size: CGSize(width: 520, height: 100))
        attach(image, "PermissionSkillBody-missingName")
        XCTAssertGreaterThanOrEqual(image.size.width, 480)
    }
}
