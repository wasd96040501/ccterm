import AppKit

/// 一个可被文字选中的区段。一个 row 可能有多个（比如 assistant row 的每段
/// markdown segment），也可能只有一个（user bubble）。
///
/// 命名靠近 AppKit 习惯：`TextSelectable` / `SelectableTextRegion` 而不是
/// Telegram 的 `MultipleSelectable` / `selectableTextViews`。
struct SelectableTextRegion {
    /// 所属 row 的稳定 id——`TranscriptSelectionController` 记账时用。
    let rowStableId: AnyHashable
    /// 在一个 row 内部的稳定 index——拷贝时用作排序键（同一 row 内多段的顺序）。
    let regionIndex: Int
    /// 区段在 row 坐标系里的 frame（layout 的可见外框）。
    /// coordinator 把全局点 (documentView 坐标) 先减 rowFrame.origin 得到 row-local 点，
    /// 再减 frameInRow.origin 得到 layout 自己的点。
    let frameInRow: CGRect
    /// 只读 layout——coordinator 做 characterIndex / selectionRange。
    let layout: TranscriptTextLayout
    /// 写入 range（`NSNotFound, 0` 表示清空）。主线程闭包。
    let setSelection: (NSRange) -> Void
}

/// Row 声明自己支持文本选中，并暴露各可选中区段。
@MainActor
protocol TextSelectable: AnyObject {
    /// 视觉顺序（自上而下）列出的所有可选中区段。
    /// 返回值允许空（比如工具占位 row）。
    var selectableRegions: [SelectableTextRegion] { get }

    /// 拷贝时的 header。一般聊天 row 为 nil；若有（如 session 分隔），
    /// 多 row 拷贝时会在前面插一行。
    var selectionHeader: String? { get }

    /// 清空本 row 内所有区段的选中。
    func clearSelection()
}
