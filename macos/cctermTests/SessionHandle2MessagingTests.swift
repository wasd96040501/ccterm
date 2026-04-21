import XCTest
import AgentSDK
@testable import ccterm

/// Covers `SessionHandle2.interrupt()` and `SessionHandle2.cancelMessage(id:)`.
///
/// interrupt 的 SDK ack 路径涉及真实 agentSession，这里只覆盖纯同步 guard 路径；
/// 完整 ack 流程由集成测试覆盖（需要真 claude CLI）。
@MainActor
final class SessionHandle2MessagingTests: XCTestCase {

    // MARK: - Helpers

    private func makeHandle(id: String = "msg-test") -> SessionHandle2 {
        let repo = SessionRepository(coreDataStack: CoreDataStack(inMemory: true))
        let h = SessionHandle2(sessionId: id, repository: repo)
        h.skipBootstrapForTesting = true
        return h
    }

    /// 构造一条 `.queued` user MessageEntry 并 append。返回 entry id。
    @discardableResult
    private func appendQueuedUser(_ handle: SessionHandle2, text: String) -> UUID {
        handle.send(text: text)
        return handle.messages.last!.id
    }

    private func appendAssistant(_ handle: SessionHandle2, text: String) -> UUID {
        let json: [String: Any] = [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [["type": "text", "text": text]],
            ],
        ]
        let msg = (try? Message2(json: json)) ?? Message2.unknown(name: "assistant", raw: json)
        let single = SingleEntry(id: UUID(), payload: .remote(msg), delivery: nil, toolResults: [:])
        handle.messages.append(.single(single))
        return single.id
    }

    // MARK: - interrupt() guard

    func test_interrupt_ignored_whenNotStarted() {
        let h = makeHandle()
        XCTAssertEqual(h.status, .notStarted)
        h.interrupt()
        XCTAssertEqual(h.status, .notStarted)
    }

    func test_interrupt_ignored_whenIdle() {
        let h = makeHandle()
        h.status = .idle
        h.interrupt()
        XCTAssertEqual(h.status, .idle)
    }

    func test_interrupt_ignored_whenStopped() {
        let h = makeHandle()
        h.status = .stopped
        h.interrupt()
        XCTAssertEqual(h.status, .stopped)
    }

    func test_interrupt_ignored_whenRespondingButNoAgentSession() {
        // 罕见边界：手动把 status 改成 responding 但没 agentSession。
        // guard 合并判断，必须 no-op，不崩。
        let h = makeHandle()
        h.status = .responding
        h.interrupt()
        XCTAssertEqual(h.status, .responding, "no agentSession 不应推进到 .interrupting")
    }

    // MARK: - cancelMessage

    func test_cancelMessage_removesQueued() {
        let h = makeHandle()
        let id = appendQueuedUser(h, text: "hello")
        XCTAssertEqual(h.messages.count, 1)

        h.cancelMessage(id: id)

        XCTAssertTrue(h.messages.isEmpty)
    }

    func test_cancelMessage_removesFailed() {
        let h = makeHandle()
        _ = appendQueuedUser(h, text: "hi")
        h.messages[0].delivery = .failed(reason: "session stopped")

        h.cancelMessage(id: h.messages[0].id)

        XCTAssertTrue(h.messages.isEmpty)
    }

    func test_cancelMessage_noOpForConfirmed() {
        // .confirmed 意味着 CLI 已在处理这条消息——本地 remove 无法让 CLI 停下，
        // 所以 cancel 必须 no-op。
        let h = makeHandle()
        _ = appendQueuedUser(h, text: "x")
        h.messages[0].delivery = .confirmed

        h.cancelMessage(id: h.messages[0].id)

        XCTAssertEqual(h.messages.count, 1, "confirmed 不可取消")
        XCTAssertEqual(h.messages[0].delivery, .confirmed)
    }

    func test_cancelMessage_noOpAfterEchoSwappedToRemote() {
        // 完整路径：send → CLI echo → confirmQueuedEntry 把 payload 换成 .remote(.user)、
        // delivery 切 .confirmed。cancelMessage 仍应 no-op（cancelable 仅 queued/failed）。
        let h = makeHandle()
        h.status = .idle
        _ = appendQueuedUser(h, text: "hi")
        let entryId = h.messages[0].id

        let echoJson: [String: Any] = [
            "type": "user",
            "uuid": entryId.uuidString.lowercased(),
            "message": ["role": "user", "content": "hi"],
        ]
        let echo = (try? Message2(json: echoJson)) ?? Message2.unknown(name: "user", raw: echoJson)
        h.receive(echo, mode: .live)
        XCTAssertEqual(h.messages[0].delivery, .confirmed)
        guard case .single(let s0) = h.messages[0],
              case .remote(.user(_)) = s0.payload else {
            XCTFail("precondition: payload should be .remote(.user)"); return
        }

        h.cancelMessage(id: entryId)

        XCTAssertEqual(h.messages.count, 1, "confirmed .remote user 不可取消")
        XCTAssertEqual(h.messages[0].delivery, .confirmed)
    }

    func test_cancelMessage_noOpForUnknownId() {
        let h = makeHandle()
        _ = appendQueuedUser(h, text: "kept")
        h.cancelMessage(id: UUID())
        XCTAssertEqual(h.messages.count, 1)
    }

    func test_cancelMessage_noOpForAssistantEntry() {
        let h = makeHandle()
        let aid = appendAssistant(h, text: "from assistant")

        h.cancelMessage(id: aid)

        XCTAssertEqual(h.messages.count, 1, "cancelMessage 仅对 user entry 生效")
    }

    func test_cancelMessage_targetsCorrectEntryAmongMany() {
        let h = makeHandle()
        _ = appendQueuedUser(h, text: "a")
        let mid = appendQueuedUser(h, text: "b")
        _ = appendQueuedUser(h, text: "c")
        XCTAssertEqual(h.messages.count, 3)

        h.cancelMessage(id: mid)

        XCTAssertEqual(h.messages.count, 2)
        let texts = h.messages.compactMap { entry -> String? in
            guard case .single(let s) = entry,
                  case .localUser(let input) = s.payload else { return nil }
            return input.text
        }
        XCTAssertEqual(texts, ["a", "c"])
    }
}
