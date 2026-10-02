import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// The model panel (design 08 *Model*) as the design's menus sheet shows it:
/// a New tab's, a live session's while Claude works (another account
/// restarts the session, a model chosen waits for the turn), with the folded
/// models expanded, and while an account's CLI hasn't answered. Review only —
/// `make test-unit FILTER=ModelPanelSnapshotTests`, then open
/// `/tmp/ccterm-screenshots/ModelPanel.png`.
@MainActor
final class ModelPanelSnapshotTests: XCTestCase {
    private typealias F = ComposerFixtures

    /// The panel on a page-coloured backdrop with some margin.
    private final class Backdrop: NSViewController {
        let panel = ModelPanelViewController()
        var expandsFirstMore = false

        override func loadView() {
            let page = NSView()
            page.wantsLayer = true
            view = page
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            addChild(panel)
            panel.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(panel.view)
            NSLayoutConstraint.activate([
                panel.view.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
                panel.view.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            ])
        }
    }

    private func render(_ model: ComposerModel, name: String) -> NSImage {
        let probe = ModelPanelViewController()
        probe.configure(with: model)
        let height = probe.preferredHeight + 24
        return ViewSnapshot.renderLightAndDark(
            {
                let backdrop = Backdrop()
                backdrop.loadViewIfNeeded()
                backdrop.panel.configure(with: model)
                backdrop.panel.selectCurrent()
                return backdrop
            }, size: CGSize(width: 324, height: height), name: name)
    }

    func testThePanelInEachCase() {
        let sonnet = ModelChoice(account: F.subscription, value: "sonnet")
        let new = F.model(.draft, settings: F.settings("opus"))
        let busy = F.model(
            F.session(.responding), settings: F.settings("opus"), pendingModel: sonnet)
        let loading = F.model(.draft, settings: F.settings("opus"), catalog: F.catalogLoadingLast)
        let fast = F.model(F.session(.idle), settings: F.settings("opus", fast: true))
        let provider = F.model(.draft, settings: F.settings("default", on: F.relay, effort: .high))
        let sheets = [new, busy, loading, fast, provider].enumerated().map { render($1, name: "\($0)") }
        let url = ViewSnapshot.writeStack(sheets, name: "ModelPanel")
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
