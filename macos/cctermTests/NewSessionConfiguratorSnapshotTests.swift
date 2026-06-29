import AppKit
import XCTest

@testable import ccterm

/// Renders the AppKit `NewSessionConfiguratorViewController` (the de-SwiftUI'd
/// compose card, migration plan §4.6) into an offscreen window so the
/// three-column layout — recents nav on the left, hero / recents-for-folder /
/// embedded input bar on the right — can be eyeballed without launching the app.
///
/// Migrated from the SwiftUI `NewSessionConfigurator` struct (deleted in this
/// phase) to the AppKit VC, rendered via `ViewSnapshot.renderViewController`.
/// Review-only (the `*SnapshotTests` suffix is skipped on the CI gate); open
/// `/tmp/ccterm-screenshots/NewSessionConfigurator.png` after running.
@MainActor
final class NewSessionConfiguratorSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private struct Scene {
        let vc: NewSessionConfiguratorViewController
        let tmp: URL
    }

    /// Build the configurator VC with a scratch recents store + an
    /// in-memory-repo manager seeded (optionally) with Recent Sessions, and the
    /// real `InputBarController` embedded. `pickFolder` seeds the draft cwd so
    /// the right column shows the hero + meta + recents-for-folder.
    private func makeScene(pickFolder: Bool, seedSessions: Bool) throws -> Scene {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ncs-snap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }

        let projectA = tmp.appendingPathComponent("worldquant-brain")
        let projectB = tmp.appendingPathComponent("ccterm")
        try FileManager.default.createDirectory(at: projectA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectB, withIntermediateDirectories: true)

        let suite = "ccterm.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let recents = RecentProjectsStore(defaults: defaults)
        recents.add(projectB.path)
        recents.add(projectA.path)  // front → selected

        let repo = InMemorySessionRepository()
        if seedSessions {
            let now = Date()
            let titles = [
                "Give me a story", "Are you still there?", "Hello?",
                "Are you a pig?", "Are you dumb?",
            ]
            for (idx, title) in titles.enumerated() {
                repo.save(
                    SessionRecord(
                        sessionId: UUID().uuidString.lowercased(), title: title, cwd: projectA.path,
                        originPath: projectA.path,
                        lastActiveAt: now.addingTimeInterval(TimeInterval(-3600 * (10 + idx))),
                        status: .created))
            }
        }
        let manager = SessionManager(repository: repo, cliClientFactory: { _ in FakeCLIClient() })

        let draftDir = tmp.appendingPathComponent("drafts")
        let draftId = UUID().uuidString.lowercased()
        let session = manager.prepareDraftSession(draftId)
        if pickFolder {
            session.draft?.setCwd(projectA.path)
            session.draft?.setOriginPath(projectA.path)
        }

        let controller = InputBarController(
            sessionManager: manager,
            inputDraftStore: InputDraftStore(directory: draftDir, debounceInterval: 0.05),
            userDefaults: UserDefaults(suiteName: "ncs-snap-bar-\(UUID().uuidString)")!,
            notificationCenter: NotificationCenter(),
            submitEnabledProvider: { $0.cwd != nil },
            onSubmit: { _, _ in })

        let vc = NewSessionConfiguratorViewController(
            sessionManager: manager,
            recents: recents,
            inputBarController: controller,
            draftSessionId: draftId,
            onResumeSession: { _ in })
        return Scene(vc: vc, tmp: tmp)
    }

    /// Wrap the card VC in a DotGrid-backed container so the snapshot mirrors
    /// the real `ComposeContentView` layering (backdrop + centered card).
    private func render(_ scene: Scene, name: String, light: Bool) -> NSImage {
        let host = NSViewController()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760))
        if light { root.appearance = NSAppearance(named: .aqua) }
        let grid = DotGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(grid)
        scene.vc.loadViewIfNeeded()
        host.addChild(scene.vc)
        scene.vc.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scene.vc.view)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: root.topAnchor),
            grid.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scene.vc.view.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            scene.vc.view.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            scene.vc.view.widthAnchor.constraint(
                equalToConstant: NewSessionConfiguratorViewController.idealWidth),
            scene.vc.view.heightAnchor.constraint(
                equalToConstant: NewSessionConfiguratorViewController.height),
        ])
        host.view = root
        let image = ViewSnapshot.renderViewController(
            host, size: CGSize(width: 1100, height: 760), settle: 0.9)
        let url = ViewSnapshot.writePNG(image, name: name)
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)
        return image
    }

    func testNewSessionConfiguratorLayout() throws {
        let scene = try makeScene(pickFolder: true, seedSessions: true)
        let image = render(scene, name: "NewSessionConfigurator", light: false)
        XCTAssertGreaterThanOrEqual(image.size.width, 1000)
        XCTAssertGreaterThanOrEqual(image.size.height, 700)
    }

    func testNewSessionConfiguratorEmptyState() throws {
        let scene = try makeScene(pickFolder: false, seedSessions: false)
        let image = render(scene, name: "NewSessionConfigurator-empty", light: false)
        XCTAssertGreaterThanOrEqual(image.size.width, 1000)
    }

    func testNewSessionConfiguratorLightAppearance() throws {
        let scene = try makeScene(pickFolder: true, seedSessions: true)
        let image = render(scene, name: "NewSessionConfigurator-light", light: true)
        XCTAssertGreaterThanOrEqual(image.size.width, 1000)
    }
}
