import AgentSDK
import AppKit
import XCTest
@testable import ccterm

/// NSWindow-backed 测试宿主：装入 `TranscriptScrollView` 并驱动它上屏 / 布局，
/// 让依赖 `clipView.bounds` / `tableView.rect(ofRow:)` 的 scroll intent、anchor
/// 等路径可测。
///
/// 生命周期：`init` → 调用 harness 方法 → 走完 test。NSWindow 不显示给用户，
/// 但有真实 layer-backing（`layoutIfNeeded` 会刷 clipView 尺寸）。
@MainActor
final class TranscriptTestHarness {

    let window: NSWindow
    let scrollView: TranscriptScrollView

    var controller: TranscriptController { scrollView.controller }
    var tableView: NSTableView { scrollView.documentView as! NSTableView }
    var clipView: NSClipView { scrollView.contentView }

    init(size: NSSize = NSSize(width: 800, height: 600)) {
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false

        scrollView = TranscriptScrollView(frame: NSRect(origin: .zero, size: size))
        scrollView.autoresizingMask = [.width, .height]
        window.contentView = scrollView

        controller.theme = .default

        // 强制一次 layout pass，tile scroller + resize clipView。
        scrollView.frame = NSRect(origin: .zero, size: size)
        scrollView.tile()
        window.layoutIfNeeded()
        window.displayIfNeeded()
    }

    deinit {
        // 显式清理，避免 @Observable tracking 在 teardown 之后还 fire。
        Task { @MainActor [window] in window.close() }
    }

    /// 单步 layout 推进：在 setEntries 后、断言前调用，确保 NSTableView 已根据
    /// 新 rows 重新计算 `rect(ofRow:)`。
    func pumpLayout() {
        scrollView.needsLayout = true
        scrollView.layoutSubtreeIfNeeded()
        scrollView.tile()
        window.layoutIfNeeded()
        window.displayIfNeeded()
    }

    /// 推 entries 进去 + 推 layout + 主线程跑尽 Phase 2 task。
    func setEntries(_ entries: [MessageEntry]) {
        controller.setEntries(entries, themeChanged: false)
        pumpLayout()
        flushRunLoop()
    }

    /// Phase 2 走 `Task.detached` 异步回主线程。跑几次 run loop 把它排出来。
    func flushRunLoop(times: Int = 6) {
        for _ in 0..<times {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        pumpLayout()
    }

    // MARK: - Observability helpers

    /// clipView 的 y 偏移（= 当前滚动位置的顶部文档坐标）。
    var clipOriginY: CGFloat { clipView.bounds.minY }

    /// clipView 的可视高度。
    var clipHeight: CGFloat { clipView.bounds.height }

    /// documentView 的总高度。
    var documentHeight: CGFloat { tableView.bounds.height }

    /// 某条 stableId 对应 row 的 documentY（minY）。找不到 → nil。
    func documentY(of stableId: AnyHashable) -> CGFloat? {
        for i in 0..<controller.rows.count where controller.rows[i].stableId == stableId {
            return tableView.rect(ofRow: i).minY
        }
        return nil
    }

    /// 当前可视 row index 范围（用 tableView.rows(in:) 算）。
    func visibleRowRange() -> NSRange {
        tableView.rows(in: clipView.bounds)
    }

    /// 末行 stableId（rows 非空时）。
    var lastRowStableId: AnyHashable? {
        controller.rows.last?.stableId
    }
}

// MARK: - Test entry builders

enum TranscriptTestEntries {

    static func userEntry(_ text: String) -> MessageEntry {
        let json: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": text],
        ]
        let msg = (try? Message2(json: json)) ?? Message2.unknown(name: "user", raw: json)
        return .single(SingleEntry(id: UUID(), payload: .remote(msg), delivery: nil, toolResults: [:]))
    }

    static func assistantEntry(_ text: String) -> MessageEntry {
        let json: [String: Any] = [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [["type": "text", "text": text]],
            ],
        ]
        let msg = (try? Message2(json: json)) ?? Message2.unknown(name: "assistant", raw: json)
        return .single(SingleEntry(id: UUID(), payload: .remote(msg), delivery: nil, toolResults: [:]))
    }

    /// 构造 N 条可区分的普通 user 消息 —— 测试场景用。
    static func manyUsers(_ count: Int, prefix: String = "message") -> [MessageEntry] {
        (0..<count).map { userEntry("\(prefix) \($0) with some body text") }
    }
}
