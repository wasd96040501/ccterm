import AppKit
import Observation
import SwiftUI
import XCTest

@testable import ccterm

/// Merge gate for the transcript-attach orchestration on the
/// **production session-switch path**. Sibling to
/// `TranscriptReentryLayoutCacheTests` (which guards the bare factory
/// API) — together they enforce a load-bearing performance invariant:
///
///     One source-phase tick must typeset each block at exactly one width.
///
/// ## Why this matters
///
/// On re-entry into a populated session, the source phase that runs
/// `tearDownTranscript + attachSession` mounts a fresh
/// `Transcript2ScrollView`. If the dataSource is bound while the
/// autolayout cascade is still in flight, `NSTableView.tile()` fires
/// `heightOfRow` queries at every intermediate width the table visits —
/// 100pt column default (clamped to `BlockStyle.minLayoutWidth = 460`),
/// the window's real width (720), and the autolayout solver's overshoot
/// at `maxLayoutWidth = 780`. Each transient width re-typesets *every*
/// block via Core Text, blows out `layoutCache`, and visibly stutters
/// the first frame on every re-entry. The fix that #198 + #205 + #206
/// landed — `make` returns an unbound shell, the host runs
/// `layoutSubtreeIfNeeded` to settle geometry, then `bindData` wires
/// the dataSource — keeps every cache entry at the single settled width.
///
/// ## What gets caught
///
/// `TranscriptReentryLayoutCacheTests` (factory only) catches a
/// regression INSIDE `TranscriptScrollViewFactory`. THIS file catches
/// regressions in the **caller** orchestration — anything that breaks
/// the contract documented on `TranscriptScrollViewFactory`:
///
///   * **Factory-internal regression** (e.g. `make` binds dataSource
///     eagerly): factory test catches; this test also catches as a
///     double-check via the production path.
///   * **Host reorders steps** (e.g. `attachSession` calls `bindData`
///     before `view.layoutSubtreeIfNeeded()`): only this test catches —
///     the factory itself is unchanged, but the caller violates the
///     order contract.
///   * **Host drops the settle step** (e.g. `view.layoutSubtreeIfNeeded()`
///     deleted, relying on a later cascade): only this test catches —
///     same shape as above, surfaces as `distinctWidths=[460, 720, 780]`.
///   * **New attach-time work that triggers a tile** (e.g. someone
///     wires a sync `setHistory` or `scrollToTail` BEFORE the host's
///     `layoutSubtreeIfNeeded`): this test catches it as multi-width
///     writes per id.
///
/// Each failure attaches a text report listing total writes, per-stage
/// width breakdown, and the first ten offending block ids with the
/// widths each was typeset at — diagnostic-rich enough that the PR
/// reviewer can identify which call moved without reproducing locally.
///
/// ## Do not weaken this gate
///
/// File name has no `Snapshot` suffix on purpose — `test-unit.sh`
/// auto-skips that pattern. This file runs on `make test-unit`
/// (the CI merge gate). If you find yourself wanting to delete or
/// `XCTSkip` this test because the fixture timing felt fragile, read
/// the §"Fixture invariants" comments inside the test body first —
/// the non-obvious bits (pre-sized container, `Task.sleep` +
/// `drainMainLoop` alternation, sanity gates on min write count + max
/// width) are each load-bearing for a specific reason documented at
/// the call site. Removing any of them silently regresses the gate to
/// "always green," which is exactly the failure mode this file's
/// predecessor was in.
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

    /// End-to-end exercise of the production session-switch path:
    /// in-memory `SessionManager` with two pre-seeded sessions, mount
    /// `ChatSessionViewController` in a framed container, attach session
    /// 1 via `present(sessionId:)`, then switch to session 2 via the same
    /// imperative entry the router calls — synchronously, in one source
    /// phase. The probe is installed on session 2's coordinator AFTER
    /// session 1 is attached, so it captures EXACTLY the writes produced
    /// by the switch's `attachSession`. Pass means every block typeset at
    /// exactly one width (the settled 720); fail means the probe saw
    /// `[460, 720]` or `[460, 720, 780]` for at least one id — the
    /// signature pattern of an attach-order regression.
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
        session1.controller.apply(.append(makeBlocks()))
        session2.controller.apply(.append(makeBlocks()))

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
        // Seed session 1 — the VC no longer self-attaches; the test
        // drives `present(sessionId:)` directly (the router's role).
        model.selection = .session(sessionId1)

        let vc = ChatSessionViewController(
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

        // Fixture invariant #1 — pre-sized container.
        //
        // Mount via a pre-sized container, NOT via
        // `window.contentViewController = vc`. On a borderless offscreen
        // window the contentViewController setter does NOT autoresize
        // vc.view to the window's content rect: vc.view stays at
        // NSView()'s default zero frame, the table's column stays at
        // its 100pt default, and the whole attach sequence runs at the
        // clamped `BlockStyle.minLayoutWidth = 460` — meaning the
        // 460→720 transition that the multi-width invariant is supposed
        // to detect never gets crossed and the test passes regardless
        // of regression. Mounting via constraints to a container that
        // already has the real frame mirrors production's
        // `ChatSessionViewController.mountSideBranch` geometry and
        // drives the cascade through to 720.
        let container = NSView(frame: NSRect(origin: .zero, size: Self.windowSize))
        window.contentView = container
        window.ccterm_orderFrontForTesting()

        vc.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            vc.view.topAnchor.constraint(equalTo: container.topAnchor),
            vc.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.layoutSubtreeIfNeeded()

        // Attach session 1 the way the router does — imperatively, on a
        // framed VC. (The VC no longer self-attaches on viewDidLoad.)
        vc.present(sessionId: sessionId1)
        // Let session 1's autolayout cascade settle so its writes are
        // fully out of the way before we install the probe.
        for _ in 0..<6 {
            try await Task.sleep(for: .milliseconds(20))
            drainMainLoop(seconds: 0.02)
        }

        // Install the probe on session 2's coordinator AFTER session 1
        // is attached, so we only capture writes that belong to the
        // switch.
        let coordinator2 = session2.controller.coordinator
        var writes: [Write] = []
        var currentStage = "pre-switch"
        coordinator2.onLayoutCacheWriteForDebug = { id, width in
            writes.append(Write(id: id, width: width, stage: currentStage))
        }
        defer { coordinator2.onLayoutCacheWriteForDebug = nil }

        // Switch to session 2 through the same imperative entry the
        // router calls. `present` runs `attachSession` synchronously —
        // build + mount + bind + scrollToTail (tiling session 2 at the
        // settled 720) + tear down session 1 — all in one source-phase
        // tick. No async observation hop to wait on.
        currentStage = "switch"
        vc.present(sessionId: sessionId2)
        XCTAssertNotNil(
            coordinator2.tableView,
            "fixture broke: session 2 table not bound after present()")

        // Flush any deferred autolayout work still queued from the swap.
        container.layoutSubtreeIfNeeded()

        let oneTickWrites = writes

        defer {
            window.contentView = nil
            window.close()
        }

        // Fixture invariant #3 — sanity gates.
        //
        // If `attachSession` didn't run, or if the fixture geometry
        // didn't reach the real window width, the probe captures an
        // empty / under-sized sample on which the per-id width check
        // is trivially satisfied. That's the silent-green failure mode
        // we MUST trip on. Expected steady state: ≥`blockCount` writes
        // (one per block; small surplus for NSTableView re-tiles is
        // fine), max width ≥ 700 (clamped down to 720 when the cascade
        // reaches the full container).
        XCTAssertGreaterThanOrEqual(
            oneTickWrites.count, Self.blockCount,
            "Fixture broke: probe captured \(oneTickWrites.count) writes — "
                + "expected ≥\(Self.blockCount). Did present(sessionId2) run "
                + "attachSession against a framed view?")
        let maxWidth = oneTickWrites.map(\.width).max() ?? 0
        XCTAssertGreaterThanOrEqual(
            maxWidth, 700,
            "Fixture broke: max width seen = \(maxWidth) — expected ≥700. "
                + "Container probably didn't cascade to the full window size.")

        try assertSingleWidthPerId(
            oneTickWrites,
            label: "ChatSessionViewController sidebar switch")
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
