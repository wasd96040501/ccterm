import XCTest
import AgentSDK
@testable import ccterm

/// `SessionHandle2.loadHistory` 两段式端到端行为：
/// - Phase A 命中 tail → `.tailLoaded(count)` 可先上屏
/// - Phase B 结束 → `.loaded`, messages 含 full 历史
/// - tailLoaded 时截取 A, loaded 时截取 B, A 应是 B 的严格**后缀**
/// - tail 区 UUID 在两次截取中稳定（prepend 检测的前提）
@MainActor
final class SessionHandle2HistoryTailTests: XCTestCase {

    private func makeHandle(id: String = "hist-tail-test") -> SessionHandle2 {
        let repo = SessionRepository(coreDataStack: CoreDataStack(inMemory: true))
        let h = SessionHandle2(sessionId: id, repository: repo)
        h.skipBootstrapForTesting = true
        return h
    }

    private static func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/large-session.jsonl")
    }

    /// `SessionHandle2HistoryTests.waitForLoaded` 已是 internal — 复用它不方便
    /// （XCTestCase 子类之间继承方法限制）。这里本地再写一份：到 terminal state
    /// 返回；超时 fail。
    private func waitForTerminal(
        _ h: SessionHandle2, timeout: TimeInterval = 10
    ) async throws {
        let start = Date()
        while true {
            switch h.historyLoadState {
            case .loaded, .failed: return
            case .notLoaded, .loadingTail, .tailLoaded:
                if Date().timeIntervalSince(start) > timeout {
                    XCTFail("timed out: \(h.historyLoadState)")
                    return
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    /// 等 tailLoaded 或更后（loaded/failed）。
    private func waitForTail(
        _ h: SessionHandle2, timeout: TimeInterval = 5
    ) async throws {
        let start = Date()
        while true {
            switch h.historyLoadState {
            case .tailLoaded, .loaded, .failed: return
            case .notLoaded, .loadingTail:
                if Date().timeIntervalSince(start) > timeout {
                    XCTFail("timed out waiting for tailLoaded: \(h.historyLoadState)")
                    return
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }

    func test_twoPhase_tailThenLoaded() async throws {
        let h = makeHandle()
        h.loadHistory(overrideURL: Self.fixtureURL(), tailTarget: 40)
        try await waitForTerminal(h)

        if case .loaded = h.historyLoadState {} else {
            XCTFail("expected .loaded, got \(h.historyLoadState)")
        }
        XCTAssertFalse(h.messages.isEmpty, "messages 应被填满")
    }

    func test_tailLoaded_fires_before_loaded() async throws {
        let h = makeHandle(id: "hist-tail-before-loaded")
        h.loadHistory(overrideURL: Self.fixtureURL(), tailTarget: 30)
        try await waitForTail(h)

        // tail 命中时至少有几条消息（receive 逻辑可能 skip 非可见类型，这里只断 > 0）。
        XCTAssertGreaterThan(h.messages.count, 0,
            "tailLoaded 时 messages 应已填充")

        // 等 loaded。
        try await waitForTerminal(h)
        if case .loaded = h.historyLoadState {} else {
            XCTFail("expected .loaded")
        }
    }

    /// 关键不变式：tailLoaded 时的 messages 是 loaded 时的严格**后缀**。Phase B
    /// 的 prepend 不能破坏 tail 的 UUID 稳定性，否则 TranscriptController 的
    /// prepend 检测会失败、视觉会跳。
    func test_tail_is_suffix_of_full() async throws {
        let h = makeHandle(id: "hist-tail-suffix-test")
        h.loadHistory(overrideURL: Self.fixtureURL(), tailTarget: 30)
        try await waitForTail(h)

        let tailSnapshot = h.messages
        guard !tailSnapshot.isEmpty else {
            XCTFail("empty tail snapshot")
            return
        }
        let tailIds = tailSnapshot.map { $0.id }

        try await waitForTerminal(h)
        let fullIds = h.messages.map { $0.id }

        XCTAssertGreaterThanOrEqual(fullIds.count, tailIds.count)
        XCTAssertEqual(
            Array(fullIds.suffix(tailIds.count)),
            tailIds,
            "tail 必须是 full 的严格后缀")
    }

    func test_idempotent_across_phase_transitions() async throws {
        let h = makeHandle(id: "hist-tail-idempotent")
        h.loadHistory(overrideURL: Self.fixtureURL(), tailTarget: 20)
        try await waitForTail(h)

        // 在 tailLoaded 期间再调一次 —— 应 no-op。
        let countBefore = h.messages.count
        h.loadHistory(overrideURL: Self.fixtureURL(), tailTarget: 20)
        XCTAssertEqual(h.messages.count, countBefore, "再调 loadHistory 不应重启流程")

        try await waitForTerminal(h)
        // loaded 后再调 —— 也应 no-op。
        let countLoaded = h.messages.count
        h.loadHistory(overrideURL: Self.fixtureURL(), tailTarget: 20)
        XCTAssertEqual(h.messages.count, countLoaded)
    }

    // MARK: - Empty / missing file paths

    func test_emptyFile_reachesLoaded() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hist-tail-empty-\(UUID().uuidString).jsonl")
        try "".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let h = makeHandle()
        h.loadHistory(overrideURL: tmp)
        try await waitForTerminal(h)
        if case .loaded = h.historyLoadState {} else {
            XCTFail("expected .loaded for empty file")
        }
        XCTAssertTrue(h.messages.isEmpty)
    }

    func test_missingFile_reachesLoaded() async throws {
        let h = makeHandle()
        let phantom = FileManager.default.temporaryDirectory
            .appendingPathComponent("hist-tail-miss-\(UUID().uuidString).jsonl")
        h.loadHistory(overrideURL: phantom)
        try await waitForTerminal(h)
        if case .loaded = h.historyLoadState {} else {
            XCTFail("expected .loaded for missing file")
        }
        XCTAssertTrue(h.messages.isEmpty)
    }

    // MARK: - Snapshot reason 序列

    /// 对 `.loaded` session 再调 `loadHistory()` —— 触发点：用户切走后切回。
    /// 必须重新 emit `.initialPaint`（即使 messages 没变），让 view 按首次打开
    /// 语义 re-paint（viewport-first + 贴底），否则 controller 残留旧 session
    /// 的 rows + 旧 reason 会出现「切回来停在上次 scroll 位置」的 bug。
    func test_loaded_reentry_emits_initialPaint() async throws {
        let h = makeHandle(id: "hist-reentry")
        h.loadHistory(overrideURL: Self.fixtureURL(), tailTarget: 20)
        try await waitForTerminal(h)
        XCTAssertEqual(h.historyLoadState, .loaded)

        let revBefore = h.snapshot.revision
        h.loadHistory(overrideURL: Self.fixtureURL(), tailTarget: 20)
        XCTAssertEqual(h.snapshot.reason, .initialPaint,
            "已 loaded 的 session 再次 loadHistory 必须 re-emit .initialPaint")
        XCTAssertGreaterThan(h.snapshot.revision, revBefore)
    }

    /// re-entry 时如果 `savedScrollAnchor` 非 nil（view 层切走前写过），
    /// emit 出来的 snapshot 必须带上 scrollHint；caller 才能用它恢复位置。
    /// nil 场景（未捕获 / 贴底）→ hint 也是 nil，view 自然 fallback 到 bottom。
    func test_loaded_reentry_passes_saved_scroll_anchor_as_hint() async throws {
        let h = makeHandle(id: "hist-reentry-hint")
        h.loadHistory(overrideURL: Self.fixtureURL(), tailTarget: 20)
        try await waitForTerminal(h)

        // 无 anchor（首次贴底）→ hint nil
        h.loadHistory(overrideURL: Self.fixtureURL())
        XCTAssertNil(h.snapshot.scrollHint, "未存 anchor 时 hint 应为 nil")

        // 模拟 view 离开时写入
        let sampleEntryId = h.messages.first!.id
        h.savedScrollAnchor = SavedScrollAnchor(entryId: sampleEntryId, topOffset: 123)

        h.loadHistory(overrideURL: Self.fixtureURL())
        XCTAssertEqual(h.snapshot.scrollHint?.entryId, sampleEntryId,
            "savedScrollAnchor 必须透传到 snapshot.scrollHint")
        XCTAssertEqual(h.snapshot.scrollHint?.topOffset, 123)
    }

    /// 两段式 loadHistory 应当依次 emit `.initialPaint`（Phase A 结束）和
    /// `.prependHistory`（Phase B 结束且 prefix 非空）。Revision 严格递增。
    func test_snapshot_emits_initialPaint_then_prependHistory() async throws {
        let h = makeHandle(id: "hist-snapshot-seq")
        XCTAssertEqual(h.snapshot.reason, .idle)
        XCTAssertEqual(h.snapshot.revision, 0)

        h.loadHistory(overrideURL: Self.fixtureURL(), tailTarget: 20)

        try await waitForTail(h)
        let tailSnap = h.snapshot
        XCTAssertEqual(tailSnap.reason, .initialPaint,
            "Phase A 结束必须 emit .initialPaint, got \(tailSnap.reason)")
        XCTAssertGreaterThan(tailSnap.revision, 0)

        try await waitForTerminal(h)
        let fullSnap = h.snapshot
        XCTAssertEqual(fullSnap.reason, .prependHistory,
            "Phase B 结束（含 prefix）必须 emit .prependHistory, got \(fullSnap.reason)")
        XCTAssertGreaterThan(fullSnap.revision, tailSnap.revision)
        XCTAssertGreaterThan(fullSnap.messages.count, tailSnap.messages.count)
    }
}
