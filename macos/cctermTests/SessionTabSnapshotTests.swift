import AgentSDK
import AppKit
import Combine
import XCTest

@testable import ccterm

/// A session tab as the window shows it, with the real composer: a New tab
/// (the New view and the composer in its slot) and a session's tab (the
/// transcript and the composer floating over its foot), light and dark, wide
/// and narrow. Review only — `make test-unit FILTER=SessionTabSnapshotTests`,
/// then open `/tmp/ccterm-screenshots/SessionTab-<name>.png`.
@MainActor
final class SessionTabSnapshotTests: XCTestCase {
    private typealias Fixture = SessionCatalogFixture
    private var fixture: SessionDirectoryFixture!

    override func setUpWithError() throws {
        fixture = try SessionDirectoryFixture()
    }

    override func tearDown() {
        fixture.remove()
    }

    private func context() -> TranscriptTab.Context {
        TranscriptTab.Context(
            sessions: .reading(),
            catalog: Just(Fixture.catalog).eraseToAnyPublisher(),
            preferences: Just(LaunchPreferences()).eraseToAnyPublisher(),
            defaults: NewSessionDefaults(defaults: UserDefaults(suiteName: "ccterm-tests-\(UUID().uuidString)")!),
            branches: BranchService(),
            recentFolders: Just([]).eraseToAnyPublisher())
    }

    private func snapshot(_ name: String, sizes: [CGSize], make: () -> SessionTabViewController) {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            defer { NSApp.appearance = nil }
            for size in sizes {
                let tab = make()
                tab.view.wantsLayer = true
                NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                    tab.view.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
                }
                let image = ViewSnapshot.renderViewController(tab, size: size, settle: 1.0)
                let png = ViewSnapshot.writePNG(image, name: "SessionTab-\(name)-\(suffix)-\(Int(size.width))")
                let attachment = XCTAttachment(contentsOfFile: png)
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testANewTab() {
        let folder = fixture.url("work")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        snapshot("new", sizes: [CGSize(width: 900, height: 640), CGSize(width: 440, height: 640)]) {
            SessionTabViewController(.draft(folder: folder, text: ""), title: SessionTabTitle.draft, context: context())
        }
    }

    func testASessionsTab() throws {
        try fixture.write(
            "-p/s.jsonl",
            [
                SessionDirectoryFixture.user("u0", parent: nil, "What does the build do?"),
                SessionDirectoryFixture.assistant("a0", parent: "u0", "It compiles the app and runs the **tests**."),
            ])
        let url = fixture.url("-p/s.jsonl")
        snapshot("session", sizes: [CGSize(width: 900, height: 480), CGSize(width: 440, height: 480)]) {
            SessionTabViewController(.session(url), title: "Build", context: context())
        }
    }
}
