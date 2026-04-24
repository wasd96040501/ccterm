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
/// Refinement 由 component 在 `refinements(content:context:)` 声明,可以 capture
/// `RefinementContext` 里的 `syntaxEngine` 等共享资源。
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

/// Framework 注入的 refinement 共享资源。新增类型(LSP / image fetcher 等)直接
/// 加字段,Sendable 由调用方保证。
struct RefinementContext: @unchecked Sendable {
    let theme: TranscriptTheme
    let syntaxEngine: SyntaxHighlightEngine?

    init(theme: TranscriptTheme, syntaxEngine: SyntaxHighlightEngine? = nil) {
        self.theme = theme
        self.syntaxEngine = syntaxEngine
    }
}
