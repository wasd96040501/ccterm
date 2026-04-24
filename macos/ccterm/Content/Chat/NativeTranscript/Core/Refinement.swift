/// Component 声明的**异步补齐活儿** —— 跨 I/O 边界 fetch 数据,得到一个
/// `ContentPatch`,framework 把 patch 折进 `Content`,重跑 layout,reload row。
///
/// ## 典型
///
/// | 场景 | Refinement 的工作 | Patch 作用 |
/// |---|---|---|
/// | Syntax highlight | 扫 code block 跨 JSCore 批量 highlight | 把 tokens 折进 `AssistantMarkdownContent.prebuilt` |
/// | Image fetch | URL → `NSImage` | 折进 `ImageContent.image` |
/// | LSP diagnostics | 跨 LSP 拿 diagnostics | 折进 `DiagnosticContent.annotations` |
///
/// ## 和老 `RowRefinement` + `RowRefinementWork` 协议对比
///
/// - 老:row(class)侧 adopt 协议 `pendingRefinements()`,work 内部 `[weak row]`
///   持 row 引用,applier 在主线程直接 `row.apply(tokens)` mutate row 字段
/// - 新:component(enum)在 `refinements(content:)` 声明活儿,work 跑完返回
///   **纯数据 `ContentPatch`**,framework 自己 "把新 content 替回 row,
///   重跑 layout,reload row"。Refinement 不持有 row 引用,不 mutate 任何东西
///
/// 结果:
/// 1. Refinement 变纯函数(input: () → output: ContentPatch),好写好测
/// 2. Row 没有可变字段(mutation 由 framework 做,经过标准 relayout 路径)
/// 3. Refinement 跨线程自然安全(`Sendable` 强制)
struct Refinement<C: TranscriptComponent>: Sendable {
    /// 异步 fetch / compute。返回后 framework 回主线程 apply。
    let run: @Sendable () async -> ContentPatch<C>
}

/// "把 refinement 结果折进 content" 的纯闭包。
///
/// Framework:`let newContent = patch.apply(oldContent)` → 用 newContent 重跑
/// `C.layout(...)` → 用新 layout reload row。
///
/// Patch 必须是**幂等的**(同 patch 二次 apply 结果等价),因为 framework
/// 在 cache 热命中 / pipeline 重入场景可能多次 apply 同一 patch。
struct ContentPatch<C: TranscriptComponent>: Sendable {
    let apply: @Sendable (C.Content) -> C.Content
}
