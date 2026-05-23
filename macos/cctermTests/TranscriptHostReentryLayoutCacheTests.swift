import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Host-driven companion to `TranscriptReentryLayoutCacheTests`.
///
/// The factory test asserts the "single source-phase tick = single
/// width per id" property against the bare attach sequence
/// (`TranscriptScrollViewFactory.make → addSubview →
/// layoutSubtreeIfNeeded → bindData → scrollToTail`). This file
/// asserts the same property against real hosts that orchestrate that
/// sequence:
///
/// 1. `TranscriptDemoViewController` — the new AppKit demo VC that
///    replaces the deleted SwiftUI bridge. Catches a regression where
///    the demo VC reorders the attach steps relative to production.
/// 2. `TranscriptDetailViewController.attachSession` — production
///    sidebar-switch path. Catches a regression where flipping
///    `MainSelectionModel.selectedSessionId` produces multiple-width
///    typesetting inside the source phase that runs `tearDownTranscript
///    + attachSession` for the new session.
///
/// Same probe (`Coordinator.onLayoutCacheWriteForDebug`) as the
/// factory test. Not a snapshot — text-only attachment — so it runs on
/// the default CI suite as a merge gate.
@MainActor
final class TranscriptHostReentryLayoutCacheTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private static let blockCount = 60
    private static let windowSize = CGSize(width: 720, height: 800)

    private func makeBlocks() -> [Block] {
        (0..<Self.blockCount).map { i in
            Block(
                id: UUID(),
                kind: .paragraph(inlines: [
                    .text(
                        "line \(i): the rain in spain falls mainly on the plain, "
                            + "and the quick brown fox jumps over the lazy dog.")
                ]))
        }
    }

    private struct Write {
        let id: UUID
        let width: CGFloat
        let stage: String
    }

    // MARK: - Demo VC

    /// Drive `TranscriptDemoViewController` end-to-end (the
    /// `loadView → viewDidLoad → mountTranscript` sequence). A demo VC
    /// that calls `TranscriptScrollViewFactory.bindData` before its
    /// host runs `layoutSubtreeIfNeeded` would typeset every block at
    /// the column's default width (clamped to `minLayoutWidth = 460`)
    /// AND at the final settled width — two distinct values in one
    /// tick — and fail this test.
    func testTranscriptDemoVCMountDoesNotRelayoutSameBlockAtMultipleWidthsInOneTick() throws {
        let controller = Transcript2Controller()
        controller.setHistory(makeBlocks())
        XCTAssertEqual(controller.blockIds.count, Self.blockCount)
        let coordinator = controller.coordinator

        var writes: [Write] = []
        var currentStage = "pre-mount"
        coordinator.onLayoutCacheWriteForDebug = { id, width in
            writes.append(Write(id: id, width: width, stage: currentStage))
        }
        defer { coordinator.onLayoutCacheWriteForDebug = nil }

        let vc = TranscriptDemoViewController(controller: controller)

        let window = NSWindow(
            contentRect: NSRect(
                origin: CGPoint(x: -30_000, y: -30_000),
                size: Self.windowSize),
            styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01

        currentStage = "contentViewController"
        window.contentViewController = vc
        window.ccterm_orderFrontForTesting()

        currentStage = "post-mount-layout"
        vc.view.layoutSubtreeIfNeeded()

        let oneTickWrites = writes

        defer {
            window.contentViewController = nil
            window.close()
        }

        try assertSingleWidthPerId(
            oneTickWrites,
            label: "TranscriptDemoViewController mount")
    }

    // MARK: - Production sidebar switch

    /// Drive the real production sidebar-switch path: a
    /// `TranscriptDetailViewController` with two pre-seeded sessions
    /// in an in-memory `SessionManager`. Mount at session 1, settle,
    /// then flip `model.selectedSessionId` to session 2 and capture
    /// the `layoutCache` writes the resulting
    /// `tearDownTranscript + attachSession` source phase emits.
    ///
    /// If `attachSession` calls `bindData` before
    /// `view.layoutSubtreeIfNeeded()`, or if anything inside the
    /// re-attach (selection observation, sheet presenter, syntax
    /// engine re-attach, history load) reorders the sequence, the
    /// target session's blocks would be typeset at both an
    /// intermediate width AND the final settled width — caught here.
    func testSidebarSwitchDoesNotRelayoutSameBlockAtMultipleWidthsInOneTick() async throws {
        let repo = InMemorySessionRepository()
        let sessionId1 = UUID().uuidString
        let sessionId2 = UUID().uuidString
        repo.save(
            SessionRecord(
                sessionId: sessionId1, title: "S1", cwd: "/tmp/s1", status: .created))
        repo.save(
            SessionRecord(
                sessionId: sessionId2, title: "S2", cwd: "/tmp/s2", status: .created))

        let manager = SessionManager(
            repository: repo,
            cliClientFactory: { _ in FakeCLIClient() })

        guard let session1 = manager.session(sessionId1),
            let session2 = manager.session(sessionId2)
        else {
            XCTFail("session materialization failed")
            return
        }
        session1.controller.setHistory(makeBlocks())
        session2.controller.setHistory(makeBlocks())

        // Per-test UserDefaults / temp directory so parallel tests
        // don't share state. The defaults suite is unique by UUID so
        // it cannot collide.
        let defaultsSuite = "ccterm-host-reentry-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let recentProjects = RecentProjectsStore(defaults: defaults)
        let activation = AppActivationTracker()
        let notifications = NotificationService(activation: activation)
        let syntaxEngine = SyntaxHighlightEngine()
        let searchBus = TranscriptSearchBus()
        let draftDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-host-reentry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: draftDir) }
        let inputDraftStore = InputDraftStore(directory: draftDir, debounceInterval: 0.05)

        let model = MainSelectionModel()
        // Start at session 1 so the VC's initial
        // handleSelectionChanged attaches to it cleanly. Default is
        // `__new_session__` which would route to the compose UI
        // instead.
        model.selectedSessionId = sessionId1

        let vc = TranscriptDetailViewController(
            model: model,
            sessionManager: manager,
            recentProjects: recentProjects,
            notifications: notifications,
            searchEngine: syntaxEngine,
            searchBus: searchBus,
            inputDraftStore: inputDraftStore)

        let window = NSWindow(
            contentRect: NSRect(
                origin: CGPoint(x: -30_000, y: -30_000),
                size: Self.windowSize),
            styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        window.contentViewController = vc
        window.ccterm_orderFrontForTesting()

        // Drain so session 1's initial attach (and its selection-
        // observation re-arm) settles before we touch session 2.
        drainMainLoop(seconds: 0.4)

        // Install the probe on session 2's coordinator AFTER session
        // 1's attach has settled so we only capture writes that
        // belong to the switch.
        let coordinator2 = session2.controller.coordinator
        var writes: [Write] = []
        var currentStage = "pre-switch"
        coordinator2.onLayoutCacheWriteForDebug = { id, width in
            writes.append(Write(id: id, width: width, stage: currentStage))
        }
        defer { coordinator2.onLayoutCacheWriteForDebug = nil }

        // Flip selection. The detail VC's observation task fires on
        // the next main-actor hop and calls handleSelectionChanged()
        // synchronously, which calls tearDownTranscript + attachSession
        // on session 2 — all inside one source-phase tick.
        currentStage = "switch"
        model.selectedSessionId = sessionId2

        // Drain to let the observation task fire + attach complete.
        drainMainLoop(seconds: 0.4)

        let oneTickWrites = writes

        defer {
            window.contentViewController = nil
            window.close()
        }

        try assertSingleWidthPerId(
            oneTickWrites,
            label: "TranscriptDetailViewController sidebar switch")
    }

    // MARK: - Helpers

    private func drainMainLoop(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(
                mode: .default,
                before: Date(timeIntervalSinceNow: 0.02))
        }
    }

    private func assertSingleWidthPerId(_ oneTickWrites: [Write], label: String) throws {
        let widthsPerId = Dictionary(grouping: oneTickWrites, by: \.id)
            .mapValues { Set($0.map(\.width)) }
        let offenders = widthsPerId.filter { $0.value.count > 1 }

        let totalWrites = oneTickWrites.count
        let uniqueIds = widthsPerId.count
        let distinctWidths = Set(oneTickWrites.map(\.width)).sorted()
        let writesPerStage = Dictionary(
            grouping: oneTickWrites, by: \.stage
        ).mapValues(\.count).sorted { $0.key < $1.key }
        let widthsPerStage = Dictionary(
            grouping: oneTickWrites, by: \.stage
        ).mapValues { Set($0.map(\.width)).sorted() }.sorted { $0.key < $1.key }

        var report = """
            \(label) — layoutCache write trace
            ────────────────────────────────────────────────────────────
            total writes        = \(totalWrites)
            unique block ids    = \(uniqueIds)  (fixture has \(Self.blockCount))
            distinct widths     = \(distinctWidths)
            writes per stage    = \(writesPerStage.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
            widths per stage    = \(widthsPerStage.map { "\($0.key)=\($0.value)" }.joined(separator: " | "))
            """

        if !offenders.isEmpty {
            var firstIndexById: [UUID: Int] = [:]
            for (i, w) in oneTickWrites.enumerated() where firstIndexById[w.id] == nil {
                firstIndexById[w.id] = i
            }
            let lines =
                offenders
                .sorted { (firstIndexById[$0.key] ?? .max) < (firstIndexById[$1.key] ?? .max) }
                .prefix(10)
                .map { id, widths in
                    let sorted = widths.sorted()
                    return "  \(id.uuidString.prefix(8))… widths=\(sorted)"
                }
            report += "\n\nOFFENDERS (\(offenders.count) ids, first 10):\n"
            report += lines.joined(separator: "\n")
        }

        let attachment = XCTAttachment(string: report)
        attachment.name = "\(label) — cache writes"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertTrue(
            offenders.isEmpty,
            "\(label): \(offenders.count) block(s) typeset at multiple widths "
                + "inside one source phase. distinctWidths=\(distinctWidths).")
    }
}
