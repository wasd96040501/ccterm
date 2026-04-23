import Foundation

/// 把 `setEntries` 的 preprocess 阶段独立出来。流程：
///
/// 1. 收集所有**新 / 更新过的** `AssistantMarkdownRow` 的 code block 请求（parse
///    在 row init 时已同步完成，不参与 Task）
/// 2. 合并去重后一次 `await engine.highlightBatch(...)`——一次 JSCore call 即
///    可拿到所有 tokens
/// 3. 回主线程把 tokens 写回各 row（`apply(codeTokens:)`）
///
/// 这一段必然是 async（engine 是 actor）。为了不跳变，controller 等这一段
/// 完成后再 merge——所以 preprocess 阶段结束 = 首屏可以安全绘出。
///
/// 可取消：`Task.isCancelled` 在 JSCore call 前后检查；新的 `setEntries` 来临
/// 时 controller cancel 掉当前 Task。
enum TranscriptPreprocessor {

    struct TimingRecord {
        var highlightMs: Int = 0
        var codeBlockCount: Int = 0
        var rowCount: Int = 0
    }

    /// Input: 新插入 / 内容更新的 `AssistantMarkdownRow`（carry-over 的不在列表
    /// 里——它们的 tokens 上轮已经贴好）。
    /// Side effect: 成功时在主线程对每个 row 调 `apply(codeTokens:)`。
    static func run(
        rows: [AssistantMarkdownRow],
        engine: SyntaxHighlightEngine?
    ) async -> TimingRecord {
        var timing = TimingRecord(rowCount: rows.count)
        guard !rows.isEmpty else { return timing }

        // 收集请求 + 记 (rowIndex, segmentIndex) → 请求在 batch 里的位置。
        var requests: [(code: String, language: String?)] = []
        var routing: [(rowIndex: Int, segmentIndex: Int)] = []
        for (rowIdx, row) in rows.enumerated() {
            for req in row.codeBlockRequests {
                requests.append((req.code, req.language))
                routing.append((rowIdx, req.segmentIndex))
            }
        }
        timing.codeBlockCount = requests.count

        guard !requests.isEmpty, let engine else {
            // 没有 code block 或没引擎——row 已经带 plain code layout，啥也不用做。
            return timing
        }

        if Task.isCancelled { return timing }

        await engine.load()
        if Task.isCancelled { return timing }

        let t0 = CFAbsoluteTimeGetCurrent()
        let batch = await engine.highlightBatch(requests)
        timing.highlightMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)

        if Task.isCancelled { return timing }
        guard batch.count == routing.count else {
            appLog(.warning, "TranscriptPreprocessor",
                "batch size mismatch: got \(batch.count) expected \(routing.count)")
            return timing
        }

        // 按 rowIndex 聚合 tokens。
        var byRow: [Int: [Int: [SyntaxToken]]] = [:]
        for (i, route) in routing.enumerated() {
            byRow[route.rowIndex, default: [:]][route.segmentIndex] = batch[i]
        }

        // 回主线程 apply。
        await MainActor.run {
            for (rowIdx, tokens) in byRow {
                if rowIdx < rows.count {
                    var anyKeyed: [AnyHashable: [SyntaxToken]] = [:]
                    for (k, v) in tokens { anyKeyed[AnyHashable(k)] = v }
                    rows[rowIdx].applyTokens(anyKeyed)
                }
            }
        }

        return timing
    }
}
