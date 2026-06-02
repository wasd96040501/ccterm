import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Renders the redesigned compose card (`NewSessionConfigurator`) into
/// an offscreen window so the new three-column layout — recents nav on
/// the left, hero / recents-for-folder / embedded input bar on the
/// right — can be eyeballed without launching the app.
///
/// Two folders are created in a temp directory and registered with a
/// scratch `RecentProjectsStore` (so the production `fileExists`
/// pruner sees real paths). A handful of `SessionRecord`s are seeded
/// into an `InMemorySessionRepository` against the first folder so
/// the "Recent Sessions" list renders with real titles + relative
/// timestamps.
///
/// The PNG is attached to the xcresult for human review only; there
/// is no golden-image diff. Open
/// `/tmp/ccterm-screenshots/NewSessionConfigurator.png` after running.
@MainActor
final class NewSessionConfiguratorSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testNewSessionConfiguratorLayout() throws {
        // Two temp project folders, registered as recents. Real paths
        // are required — RecentProjectsStore prunes anything that does
        // not pass `FileManager.fileExists`.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ncs-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }

        let projectA = tmp.appendingPathComponent("worldquant-brain")
        let projectB = tmp.appendingPathComponent("ccterm")
        try FileManager.default.createDirectory(at: projectA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectB, withIntermediateDirectories: true)

        // Scratch UserDefaults so the store does not bleed into the
        // user's real recents list during parallel test runs.
        let defaults = UserDefaults(suiteName: "ccterm.test.\(UUID().uuidString)")!
        let recents = RecentProjectsStore(defaults: defaults)
        recents.add(projectB.path)
        recents.add(projectA.path)  // adds at the front → ends up selected

        // Five session records all rooted at projectA — gives the
        // "Recent Sessions" list real content.
        let repo = InMemorySessionRepository()
        let now = Date()
        let titles = [
            "Give me a story",
            "Are you still there?",
            "Hello?",
            "Are you a pig?",
            "Are you dumb?",
        ]
        for (idx, title) in titles.enumerated() {
            let record = SessionRecord(
                sessionId: UUID().uuidString.lowercased(),
                title: title,
                cwd: projectA.path,
                originPath: projectA.path,
                lastActiveAt: now.addingTimeInterval(TimeInterval(-3600 * (10 + idx))),
                status: .created
            )
            repo.save(record)
        }
        let manager = SessionManager(repository: repo)

        // Inject the picked folder so the right column shows the
        // hero with the project name + branch + recent sessions.
        let folderBinding = Binding<String?>.constant(projectA.path)
        let worktreeBinding = Binding<Bool>.constant(false)
        let branchBinding = Binding<String?>.constant(nil)

        let view = ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            NewSessionConfigurator(
                folderPath: folderBinding,
                useWorktree: worktreeBinding,
                sourceBranch: branchBinding,
                inputBar: {
                    // Placeholder bar with the same height the real
                    // pill produces — keeps the layout truthful
                    // without dragging the session-aware
                    // `InputBarChrome` (and its required `Session`)
                    // into the test surface.
                    Color.gray.opacity(0.18)
                        .frame(height: 64)
                        .clipShape(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                }
            )
        }
        .frame(width: 1100, height: 760)
        .environment(recents)
        .environment(manager)
        .environment(RemoteHostStore())

        let image = ViewSnapshot.render(
            view, size: CGSize(width: 1100, height: 760), settle: 0.9)
        let url = ViewSnapshot.writePNG(image, name: "NewSessionConfigurator")

        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "NewSessionConfigurator.png"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertGreaterThanOrEqual(image.size.width, 1000)
        XCTAssertGreaterThanOrEqual(image.size.height, 700)
    }

    /// Same fixture as the main test, but with no folder picked yet —
    /// captures the empty hero ("Start Building" without a project
    /// name), the "Pick a project on the left to begin." subtitle,
    /// and the empty recent-sessions placeholder.
    func testNewSessionConfiguratorEmptyState() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ncs-snapshot-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }

        let projectA = tmp.appendingPathComponent("worldquant-brain")
        let projectB = tmp.appendingPathComponent("ccterm")
        try FileManager.default.createDirectory(at: projectA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectB, withIntermediateDirectories: true)

        let defaults = UserDefaults(suiteName: "ccterm.test.\(UUID().uuidString)")!
        let recents = RecentProjectsStore(defaults: defaults)
        recents.add(projectB.path)
        recents.add(projectA.path)

        let repo = InMemorySessionRepository()
        let manager = SessionManager(repository: repo)

        let folderBinding = Binding<String?>.constant(nil)
        let worktreeBinding = Binding<Bool>.constant(false)
        let branchBinding = Binding<String?>.constant(nil)

        let view = ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            NewSessionConfigurator(
                folderPath: folderBinding,
                useWorktree: worktreeBinding,
                sourceBranch: branchBinding,
                inputBar: {
                    Color.gray.opacity(0.18)
                        .frame(height: 64)
                        .clipShape(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                }
            )
        }
        .frame(width: 1100, height: 760)
        .environment(recents)
        .environment(manager)
        .environment(RemoteHostStore())

        let image = ViewSnapshot.render(
            view, size: CGSize(width: 1100, height: 760), settle: 0.9)
        let url = ViewSnapshot.writePNG(image, name: "NewSessionConfigurator-empty")

        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "NewSessionConfigurator-empty.png"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertGreaterThanOrEqual(image.size.width, 1000)
    }

    /// Same fixture as the main test, but rendered in **light**
    /// appearance. Catches issues where the left-column tint reads
    /// as a saturated patch on the lighter `ultraThinMaterial` base.
    func testNewSessionConfiguratorLightAppearance() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ncs-snapshot-light-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }

        let projectA = tmp.appendingPathComponent("worldquant-brain")
        let projectB = tmp.appendingPathComponent("ccterm")
        try FileManager.default.createDirectory(at: projectA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectB, withIntermediateDirectories: true)

        let defaults = UserDefaults(suiteName: "ccterm.test.\(UUID().uuidString)")!
        let recents = RecentProjectsStore(defaults: defaults)
        recents.add(projectB.path)
        recents.add(projectA.path)

        let repo = InMemorySessionRepository()
        let now = Date()
        let titles = [
            "Give me a story", "Are you still there?", "Hello?",
            "Are you a pig?", "Are you dumb?",
        ]
        for (idx, title) in titles.enumerated() {
            let record = SessionRecord(
                sessionId: UUID().uuidString.lowercased(),
                title: title,
                cwd: projectA.path,
                originPath: projectA.path,
                lastActiveAt: now.addingTimeInterval(TimeInterval(-3600 * (10 + idx))),
                status: .created
            )
            repo.save(record)
        }
        let manager = SessionManager(repository: repo)

        let folderBinding = Binding<String?>.constant(projectA.path)
        let worktreeBinding = Binding<Bool>.constant(false)
        let branchBinding = Binding<String?>.constant(nil)

        let view = ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            NewSessionConfigurator(
                folderPath: folderBinding,
                useWorktree: worktreeBinding,
                sourceBranch: branchBinding,
                inputBar: {
                    Color.gray.opacity(0.18)
                        .frame(height: 64)
                        .clipShape(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                }
            )
        }
        .frame(width: 1100, height: 760)
        .environment(recents)
        .environment(manager)
        .environment(RemoteHostStore())
        .preferredColorScheme(.light)

        let image = ViewSnapshot.render(
            view, size: CGSize(width: 1100, height: 760), settle: 0.9)
        let url = ViewSnapshot.writePNG(image, name: "NewSessionConfigurator-light")

        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "NewSessionConfigurator-light.png"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertGreaterThanOrEqual(image.size.width, 1000)
    }
}
