import Foundation

/// 格式化 session-open 性能指标日志。与 `TranscriptController` / `ChatHistoryView`
/// 解耦 —— 纯函数，便于做字符串快照测试。
///
/// 日志格式：`open ttfp=23ms full=180ms entries=420 phase1Rows=12 cacheHit=3
/// cacheMiss=0 width=780 fallback=0 scroll=bottom budget=ok`
///
/// 所有数字 / 字符串字段都用 `key=value` 语法，空格分隔，便于 `grep` / `awk`。
enum OpenMetrics {

    struct Snapshot {
        /// 从用户触发 `ChatHistoryView.task` → 首次 Phase 1 merge 完成（用户看到内容）。
        let ttfpMs: Int
        /// full = ttfp + Phase 2 merge 完成。nil 代表 Phase 2 还没跑完（一次性指标只
        /// 在第一次回 main 时打印）。
        let fullMs: Int?
        /// entries.count（Model 输入规模）。
        let entryCount: Int
        /// Phase 1 synchronously mounted rows count。
        let phase1Rows: Int
        /// 本次 setEntries 内的 cache hit / miss（从 TranscriptPrepareCache delta 取）。
        let cacheHit: Int
        let cacheMiss: Int
        /// 进 Phase 1 时使用的 row layout 宽度（clamp 后）。
        let width: Int
        /// viewport height 来源 tag —— `"ok"` / `"fallback-table"` / `"fallback-const"`。
        let viewportTag: String
        /// 本次 setEntries 决定的 scroll intent tag —— `preserve` / `bottom` / `anchor`。
        let scrollTag: String
    }

    static func format(_ s: Snapshot) -> String {
        var parts: [String] = []
        parts.append("open")
        parts.append("ttfp=\(s.ttfpMs)ms")
        if let fullMs = s.fullMs {
            parts.append("full=\(fullMs)ms")
        }
        parts.append("entries=\(s.entryCount)")
        parts.append("phase1Rows=\(s.phase1Rows)")
        parts.append("cacheHit=\(s.cacheHit)")
        parts.append("cacheMiss=\(s.cacheMiss)")
        parts.append("width=\(s.width)")
        parts.append("fallback=\(s.viewportTag == "ok" ? "0" : "1")")
        parts.append("budget=\(s.viewportTag)")
        parts.append("scroll=\(s.scrollTag)")
        return parts.joined(separator: " ")
    }
}
