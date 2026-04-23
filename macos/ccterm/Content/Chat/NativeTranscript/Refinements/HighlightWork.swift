import AppKit

/// Highlight 一行里所有未着色 code block 的 refinement work。
///
/// **每 row 一个 work**（不是每 segment 一个）——因为 `row.applyTokens` 的
/// 语义是"用给定 dict 重建整 row 的 prebuilt"，要一次喂全部 segment 的 tokens
/// 才对。work 内部再用 `TaskGroup` 并发调 `engine.highlight(...)` per segment；
/// engine 侧做 coalescing，N 个 segment 合并成一次 JSCore batch call。
///
/// run() 返回的 applier 在主线程执行，`[weak row]` 捕获——row 释放 = no-op；
/// 否则一次性调 `row.applyTokens([idx: tokens])` 把所有 segment tokens 喂进去。
struct HighlightWork: RowRefinementWork {
    let row: WeakRowBox
    let segments: [Segment]
    let engine: SyntaxHighlightEngine

    struct Segment: Sendable {
        let segmentIndex: Int
        let code: String
        let language: String?
    }

    func run() async -> @MainActor @Sendable () -> Void {
        // per-segment 并发请求。engine 内部 coalesce 掉同 tick 的所有
        // `highlight(...)`，实际只跨一次 JSCore batch。
        var results: [Int: [SyntaxToken]] = [:]
        await withTaskGroup(of: (Int, [SyntaxToken]).self) { group in
            for seg in segments {
                group.addTask {
                    let tokens = await engine.highlight(
                        code: seg.code, language: seg.language)
                    return (seg.segmentIndex, tokens)
                }
            }
            for await (idx, tokens) in group {
                results[idx] = tokens
            }
        }
        let snapshot = results
        let boxedRow = row
        return { @MainActor @Sendable in
            var dict: [AnyHashable: [SyntaxToken]] = [:]
            for (k, v) in snapshot { dict[AnyHashable(k)] = v }
            boxedRow.row?.applyTokens(dict)
        }
    }

    /// `Sendable` box 包裹 weak ref——`HighlightWork` 要进 `TaskGroup` 需要
    /// `Sendable`；Swift 5.9 里 `weak var` 不能直接 `Sendable`，用 `@unchecked`
    /// 小 wrapper 绕过（row 是 `@MainActor` class，applier 也在 MainActor 上读，
    /// 实际线程安全）。
    struct WeakRowBox: @unchecked Sendable {
        weak var row: AssistantMarkdownRow?
    }
}
