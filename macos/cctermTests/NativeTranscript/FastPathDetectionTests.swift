import AgentSDK
import AppKit
import XCTest
@testable import ccterm

/// 单元覆盖 `TranscriptController.detectPureAppend` 的识别矩阵 —— 流式场景最
/// 常见的几种 entry 变化都要被正确分类：
/// - 纯尾部追加 → 命中
/// - 前缀被破坏(删、插、重排)→ 不命中
/// - 长度不变但 id 变(streaming "in-place update")→ 不命中(保守,走 slow path)
/// - 空 → 空 → 不命中
@MainActor
final class FastPathDetectionTests: XCTestCase {

    private func makeController() -> TranscriptController {
        let tv = TranscriptTableView(frame: NSRect(x: 0, y: 0, width: 720, height: 600))
        return TranscriptController(tableView: tv)
    }

    private func ids(_ count: Int, seed: UInt8 = 0) -> [UUID] {
        (0..<count).map { i in
            // 稳定的可重复 UUID(每次 test 相同 seed → 相同 id 序列,方便比对)。
            UUID(uuid: (seed, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(i)))
        }
    }

    // MARK: - Pure append

    func testPureAppendOfOneEntry() {
        let controller = makeController()
        let old = ids(3)
        controller._testHook_setLastEntriesSignature(old)

        let new = old + [UUID()]
        let appended = controller._testHook_detectPureAppend(newIDs: new)
        XCTAssertNotNil(appended)
        XCTAssertEqual(appended?.count, 1)
    }

    func testPureAppendOfMultipleEntries() {
        let controller = makeController()
        let old = ids(5)
        controller._testHook_setLastEntriesSignature(old)

        let new = old + [UUID(), UUID(), UUID()]
        let appended = controller._testHook_detectPureAppend(newIDs: new)
        XCTAssertEqual(appended?.count, 3)
    }

    // MARK: - Negative cases

    /// 前缀里任何 id 不匹配 → 不命中。
    func testMidPrefixMismatchRejects() {
        let controller = makeController()
        let old = ids(3)
        controller._testHook_setLastEntriesSignature(old)

        var new = old
        new[1] = UUID()   // 替换中间一条
        new.append(UUID())
        XCTAssertNil(controller._testHook_detectPureAppend(newIDs: new))
    }

    /// 新 IDs 数量 <= 旧(删除或同长度)→ 不命中。
    func testSameLengthRejects() {
        let controller = makeController()
        let old = ids(3)
        controller._testHook_setLastEntriesSignature(old)
        XCTAssertNil(controller._testHook_detectPureAppend(newIDs: old))
    }

    func testShorterRejects() {
        let controller = makeController()
        controller._testHook_setLastEntriesSignature(ids(3))
        XCTAssertNil(controller._testHook_detectPureAppend(newIDs: ids(2)))
    }

    /// 中间插入:old=[A,B,C] new=[A,X,B,C] → 不命中。
    func testMiddleInsertionRejects() {
        let controller = makeController()
        let a = UUID(), b = UUID(), c = UUID(), x = UUID()
        controller._testHook_setLastEntriesSignature([a, b, c])
        XCTAssertNil(controller._testHook_detectPureAppend(newIDs: [a, x, b, c]))
    }

    /// 空旧 + 非空新 → 全部视作追加(命中)。冷启动常见路径。
    func testEmptyPreviousWithNewEntries() {
        let controller = makeController()
        controller._testHook_setLastEntriesSignature([])
        let new = ids(3)
        let appended = controller._testHook_detectPureAppend(newIDs: new)
        XCTAssertEqual(appended?.count, 3)
    }

    /// 双空 → 不命中(new.count > old.count 失败)。
    func testEmptyPreviousAndNewRejects() {
        let controller = makeController()
        controller._testHook_setLastEntriesSignature([])
        XCTAssertNil(controller._testHook_detectPureAppend(newIDs: []))
    }
}

