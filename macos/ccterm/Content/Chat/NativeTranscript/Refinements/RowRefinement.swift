import AppKit

/// Row 自报异步"content refinement"工作——延迟到达、需要回灌的数据
/// （syntax highlight / image fetch / lsp diagnostics / …）。controller
/// 的 refinement scheduler 只认这个协议，**不 care 工作具体是啥**
/// （不出现 "highlight" / "image" / "lsp" 等字样）。
///
/// 加一种新 refinement = 新建一个 `RowRefinementWork` 具体实现 +
/// row 在 `pendingRefinements()` 里 emit，**controller 零改动**。
@MainActor
protocol RowRefinement: AnyObject {
    /// 当前有哪些 refinement work 需要跑。scheduler 把它们并发 run()，
    /// 完成后回主线程执行 applier。空 = 无活儿要干。
    func pendingRefinements() -> [any RowRefinementWork]
}

/// 一件异步 refinement 工作。`run()` 跑完返回一个 `@MainActor` applier——
/// controller 只把 applier 回主线程执行，**不知道它做什么**（apply tokens /
/// 贴图片 / 贴 diagnostic 等等）。engine 调用、结果映射都封装在实现内部。
protocol RowRefinementWork: Sendable {
    /// 异步跑这件活儿。返回一个主线程 applier。并发执行（各 engine 自己
    /// 做聚合——如 `SyntaxHighlightEngine` 的同 tick coalescing）。
    func run() async -> @MainActor @Sendable () -> Void
}
