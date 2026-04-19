import XCTest
import AgentSDK
@testable import ccterm

/// Covers `SessionHandle2.loadHistory()`. 复用 `receive(_:mode:.replay)`
/// 的 ingest 路径，所以这里只验证：
/// - parseJSONL 纯函数解析 / 错误路径
/// - loadHistory 的 state machine（notLoaded → loading → loaded/failed）
/// - 幂等性
/// - 与 `start()` 正交
@MainActor
final class SessionHandle2HistoryTests: XCTestCase {

    // MARK: - Helpers

    private func makeHandle(id: String = "hist-test") -> SessionHandle2 {
        let repo = SessionRepository(coreDataStack: CoreDataStack(inMemory: true))
        let h = SessionHandle2(sessionId: id, repository: repo)
        h.skipBootstrapForTesting = true
        return h
    }

    private static func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
    }

    private func waitForLoaded(_ handle: SessionHandle2, timeout: TimeInterval = 5) async throws {
        let start = Date()
        while true {
            switch handle.historyLoadState {
            case .loaded, .failed: return
            case .loading, .notLoaded:
                if Date().timeIntervalSince(start) > timeout {
                    XCTFail("timed out waiting for loadHistory to settle, last=\(handle.historyLoadState)")
                    return
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    // MARK: - parseJSONL: pure

    func test_parseJSONL_nilURL_returnsEmpty() {
        let result = SessionHandle2.parseJSONL(at: nil)
        switch result {
        case .success(let msgs): XCTAssertTrue(msgs.isEmpty)
        case .failure: XCTFail("nil URL 应 success([])")
        }
    }

    func test_parseJSONL_missingFile_returnsEmpty() {
        let phantom = FileManager.default.temporaryDirectory
            .appendingPathComponent("sh2-phantom-\(UUID().uuidString).jsonl")
        let result = SessionHandle2.parseJSONL(at: phantom)
        switch result {
        case .success(let msgs): XCTAssertTrue(msgs.isEmpty)
        case .failure: XCTFail("missing file 应 success([])")
        }
    }

    func test_parseJSONL_realFixture_returnsMessages() throws {
        let url = Self.fixtureURL("replay-sample.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("fixture not found at \(url.path)")
        }
        let result = SessionHandle2.parseJSONL(at: url)
        switch result {
        case .success(let msgs):
            XCTAssertFalse(msgs.isEmpty, "replay-sample.jsonl 应能解出消息")
        case .failure(let err):
            XCTFail("parseJSONL failed: \(err)")
        }
    }

    func test_parseJSONL_skipsGarbageLines() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sh2-garbage-\(UUID().uuidString).jsonl")
        let content = """
        {"type":"user","message":{"role":"user","content":"hi"},"session_id":"x"}
        this is not json
        {malformed
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"yo"}]},"session_id":"x"}
        """
        try content.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = SessionHandle2.parseJSONL(at: tmp)
        switch result {
        case .success(let msgs):
            XCTAssertEqual(msgs.count, 2, "garbage 行跳过，两条有效保留")
        case .failure(let err):
            XCTFail("should not fail, got \(err)")
        }
    }

    // MARK: - loadHistory: state machine

    func test_loadHistory_startsLoading_synchronously() {
        let h = makeHandle()
        if case .notLoaded = h.historyLoadState {} else {
            return XCTFail("expected initial .notLoaded")
        }
        h.loadHistory(overrideURL: nil)

        // 同步部分应已切到 .loading（task 还在排队）
        switch h.historyLoadState {
        case .loading, .loaded:
            break  // .loaded 也算接受（极快情况下 task 已完成）
        default:
            XCTFail("expected .loading after loadHistory call, got \(h.historyLoadState)")
        }
    }

    func test_loadHistory_emptyFile_reachesLoaded() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sh2-empty-\(UUID().uuidString).jsonl")
        try "".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let h = makeHandle()
        h.loadHistory(overrideURL: tmp)

        try await waitForLoaded(h)
        if case .loaded = h.historyLoadState {} else {
            XCTFail("expected .loaded, got \(h.historyLoadState)")
        }
        XCTAssertTrue(h.messages.isEmpty)
    }

    func test_loadHistory_missingFile_reachesLoaded() async throws {
        let h = makeHandle()
        let phantom = FileManager.default.temporaryDirectory
            .appendingPathComponent("sh2-miss-\(UUID().uuidString).jsonl")
        h.loadHistory(overrideURL: phantom)

        try await waitForLoaded(h)
        if case .loaded = h.historyLoadState {} else {
            XCTFail("missing file 应 .loaded(empty)，got \(h.historyLoadState)")
        }
        XCTAssertTrue(h.messages.isEmpty)
    }

    func test_loadHistory_fixture_populatesMessagesViaReceive() async throws {
        let url = Self.fixtureURL("replay-sample.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("fixture not found at \(url.path)")
        }

        let h = makeHandle()
        h.loadHistory(overrideURL: url)

        try await waitForLoaded(h, timeout: 10)
        if case .loaded = h.historyLoadState {} else {
            XCTFail("expected .loaded, got \(h.historyLoadState)")
        }
        XCTAssertFalse(h.messages.isEmpty, "receive(.replay) 应填充 messages")

        // replay mode 不该置 hasUnread（即使 isFocused == false）
        XCTAssertFalse(h.hasUnread, "replay 不触发 hasUnread")
    }

    func test_loadHistory_idempotent_whileLoading() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sh2-idem-\(UUID().uuidString).jsonl")
        // 不创建文件，让 parse 走 missing 分支（最快路径）
        let h = makeHandle()

        h.loadHistory(overrideURL: tmp)
        // 立刻再调——状态应不被打回 notLoaded / 重新 loading
        let before = h.historyLoadState
        h.loadHistory(overrideURL: tmp)
        let after = h.historyLoadState

        switch (before, after) {
        case (.loading, .loading), (.loaded, .loaded):
            break
        default:
            XCTFail("idempotency broke: before=\(before) after=\(after)")
        }
    }

    func test_loadHistory_idempotent_afterLoaded() async throws {
        let h = makeHandle()
        let phantom = FileManager.default.temporaryDirectory
            .appendingPathComponent("sh2-idem2-\(UUID().uuidString).jsonl")
        h.loadHistory(overrideURL: phantom)
        try await waitForLoaded(h)

        // 强行改一个字段作为哨兵，再调一次 loadHistory —— 不应回退或重跑
        let sentinelCount = h.messages.count  // 应为 0
        h.loadHistory(overrideURL: phantom)

        if case .loaded = h.historyLoadState {} else {
            XCTFail("expected .loaded after second call")
        }
        XCTAssertEqual(h.messages.count, sentinelCount)
    }

    // MARK: - Orthogonal to start()

    func test_loadHistory_worksWhileNotStarted() async throws {
        let h = makeHandle()
        XCTAssertEqual(h.status, .notStarted)

        let phantom = FileManager.default.temporaryDirectory
            .appendingPathComponent("sh2-notstarted-\(UUID().uuidString).jsonl")
        h.loadHistory(overrideURL: phantom)
        try await waitForLoaded(h)

        XCTAssertEqual(h.status, .notStarted, "loadHistory 不应改 status")
        if case .loaded = h.historyLoadState {} else {
            XCTFail("expected .loaded")
        }
    }
}

// MARK: - HistoryLoadState debug description shim

extension SessionHandle2.HistoryLoadState: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notLoaded: return "notLoaded"
        case .loading: return "loading"
        case .loaded: return "loaded"
        case .failed(let r): return "failed(\(r))"
        }
    }
}
