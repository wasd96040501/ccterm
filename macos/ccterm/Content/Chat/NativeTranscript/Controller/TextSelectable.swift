import AppKit

/// Row 内跨 fragment 的稳定排序键。
///
/// `fragmentOrdinal` = fragment 在 row `cachedFragments` 数组里的下标；
/// `subIndex` = fragment 内的 sub-region 序号（例如 table 第几个 cell、list
/// 第几段文本）。Cmd-C 拼接按 `(rowIndex, ordering)` 字典序。
///
/// 用 struct + Comparable + Hashable 取代裸元组——元组不能 Hashable、不能
/// 进 Set / Dictionary 键位，且 `<` 语义要手写。之前 `tag * 1_000_000 +
/// ...` 的编码把这个排序需求强行塞进 Int，会在大 table（>1000 cell）时溢出
/// 串位。显式字典序两级 Int 无歧义。
struct Ordering: Hashable, Comparable {
    let fragmentOrdinal: Int
    let subIndex: Int

    static func < (lhs: Ordering, rhs: Ordering) -> Bool {
        if lhs.fragmentOrdinal != rhs.fragmentOrdinal {
            return lhs.fragmentOrdinal < rhs.fragmentOrdinal
        }
        return lhs.subIndex < rhs.subIndex
    }
}

/// 一个可被文字选中的区段。一个 row 可能有多个（比如 assistant row 的每段
/// markdown segment），也可能只有一个（user bubble）。
///
/// 命名靠近 AppKit 习惯：`TextSelectable` / `SelectableTextRegion` 而不是
/// Telegram 的 `MultipleSelectable` / `selectableTextViews`。
/// 决定 SelectionController 对某个 region 用哪套几何规则。
///
/// - `.flow`：流式文本（assistant markdown 段落、user bubble、list item）。
///   沿用 upper/lower 顺序模型：上半 row 起 → 中间 row 整段 → 下半 row 止。
///   drag 的 x 不参与过滤——文本占满 row 宽，横向窄拖一样要选整行文字。
/// - `.cell`：二维网格单元（table cell）。用 drag 包围矩形的 x 过滤（列不在
///   x 范围就整列跳过）+ y 裁切（行切 anchor/focus 的上下半）。drag 不穿过
///   的列一点都不选——Excel 式语义。
enum SelectionMode {
    case flow
    case cell
}

struct SelectableTextRegion {
    /// 所属 row 的稳定 id——`TranscriptSelectionController` 记账时用。
    let rowStableId: AnyHashable
    /// Row 内的稳定排序键——拷贝时用作字典序排序。
    let ordering: Ordering
    /// Row 内 x/y 同时决定 drag 是否命中的模式。
    let mode: SelectionMode
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
