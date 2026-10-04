import AgentSDK
import AppKit
import Components
import XCTest

@testable import ccterm

/// The New view's branch menu — the one menu the app still builds — in a
/// `MenuPanelViewController` beside the design's playground opening it from its New tab
/// (`<scheme>-live-branch` in `make design-shots`), with the branches the
/// playground's ccterm has. The composer's menus and the folder menu are the
/// package's own: `ComposerSpecimen`, `NewSessionSpecimen`.
/// Review only — `TEST_LANGUAGE=en make test-unit FILTER=MenuPanelSnapshotTests`
/// after `make design-shots`, then `/tmp/ccterm-parity/<scheme>-live-<menu>.png`.
/// Needs the display awake.
@MainActor
final class MenuPanelSnapshotTests: XCTestCase {
    private func branches() -> NewSessionModel.BranchList {
        func item(
            _ name: String, _ subtitle: String? = nil, enabled: Bool = true, chosen: Bool = false
        )
            -> NewSessionModel.BranchItem
        {
            NewSessionModel.BranchItem(name: name, subtitle: subtitle, isEnabled: enabled, isChosen: chosen)
        }
        return NewSessionModel.BranchList(
            local: [
                item("main", String(localized: "Checked out here"), chosen: true),
                item("live-session-design", String(localized: "Checked out in another worktree"), enabled: false),
                item("fix-gutter-overflow"), item("exactlist-bench"), item("settings-accounts"),
            ],
            remote: [item("origin/release/1.4"), item("origin/sidebar-icons")])
    }

    private func content(of menu: String) -> MenuContent {
        NewSessionMenu.branchMenu(of: branches(), query: "").menuContent
    }

    func testEveryMenuAgainstTheDesign() async throws {
        var report: [String] = []
        for scheme in DesignParity.Scheme.allCases {
            for menu in ["branch"] {
                let id = "live-\(menu)"
                let part = try DesignParity.part(id, scheme)
                let controller = MenuPanelViewController()
                controller.configure(with: content(of: menu))
                // Where the menu opens, it holds the checked item in view.
                controller.loadViewIfNeeded()
                let size = controller.preferredSize
                report.append(
                    "\(scheme.rawValue) \(menu): design \(part.width) × \(part.height), ours \(size.width) × \(size.height)"
                )
                let image = try await CompositedCapture.render(controller, size: size, appearance: scheme.appearance)
                let attachment = XCTAttachment(contentsOfFile: try DesignParity.write(id, scheme, ours: image))
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        let sizes = XCTAttachment(string: report.joined(separator: "\n"))
        sizes.lifetime = .keepAlways
        add(sizes)
    }
}
