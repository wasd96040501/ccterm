import AppKit
import XCTest
@testable import ccterm

/// 覆盖列宽分配算法（CSS-like min/max 模型）。
///
/// badcase 背景：在 2026-04 之前用「单行不换行宽度」等比缩的做法，当一列内容特别
/// 长时 scale 很小，本来应该窄的列（"类别"两个字）也会被按相同比例压到 1 pt 级别，
/// 从而一列一字垂直堆叠。新算法让短列永远不被压到自己的 minContent 以下。
@MainActor
final class TranscriptTableLayoutTests: XCTestCase {
    private func makeLayout(markdown: String, maxWidth: CGFloat) -> TranscriptTableLayout {
        let doc = MarkdownDocument(parsing: markdown)
        var table: MarkdownTable?
        for seg in doc.segments {
            if case .table(let t) = seg { table = t; break }
        }
        guard let table else {
            XCTFail("no table parsed")
            return TranscriptTableLayout.make(
                contents: TranscriptTableCellContents.make(
                    table: MarkdownTable(header: [], alignments: [], rows: []),
                    builder: MarkdownAttributedBuilder(theme: TranscriptTheme.default.markdown)),
                theme: TranscriptTheme.default,
                maxWidth: maxWidth)
        }
        let theme = TranscriptTheme.default
        let builder = MarkdownAttributedBuilder(theme: theme.markdown)
        let contents = TranscriptTableCellContents.make(table: table, builder: builder)
        return TranscriptTableLayout.make(contents: contents, theme: theme, maxWidth: maxWidth)
    }

    /// 截图 badcase 原样：4 列、某列内容特别长。短中文列（"类别"）最终宽度应当
    /// 足够容纳两个汉字同行不断行；而不是被等比缩到一列一字。
    func testNarrowColumn_notCrushedByLongColumn() {
        let md = """
        | 类别 | 问题 | 位置 | 建议 |
        |------|------|------|------|
        | 潜在 Bug | `waitForSessionInit` 的超时 Task 不持有自己的 continuation 引用。若 wait1 被 wait2 supersede, wait1 的 30s 超时 Task 仍在跑,到期后会 resume wait2 的 continuation 为 .timeout | +CLIBinding.swift:89-94 | 用 generation counter 或直接捕获 cont 引用并比对身份 |
        | 潜在 Bug | `handleProcessExit` 调 `fulfillSessionInit()`,实际上是 `cont?.resume()` (成功), 而不是抛错。进程死掉时等待方收到 success | +CLIBinding.swift:173 | 新增 SessionInitError.processExited 并 resume(throwing:) |
        """
        let layout = makeLayout(markdown: md, maxWidth: 560)
        XCTAssertEqual(layout.columnWidths.count, 4)

        // 第 0 列 "类别" 的 header cell 单行排版高度 = 一行高度；若被压到单字宽度
        // 会变成 2 行。通过 row 0 col 0 的 measuredWidth vs. 高度间接验证。
        let headerCellLayout = layout.cells[0][0]
        let singleLineHeight = headerCellLayout.lineRects.first?.height ?? 0
        XCTAssertGreaterThan(singleLineHeight, 0)
        // "类别" 两个字,只占一行——如果被压成单字/行,这里会 >= 2 * singleLineHeight
        XCTAssertLessThan(
            headerCellLayout.totalHeight,
            singleLineHeight * 1.8,
            "short header column should not wrap into multiple lines")

        // 列宽和 ≈ maxWidth（允许 1pt round 误差）
        XCTAssertEqual(layout.columnWidths.reduce(0, +), 560, accuracy: 1.5)

        // 短列拿到的权重远小于长列
        XCTAssertLessThan(layout.columnWidths[0], layout.columnWidths[1])
    }

    /// sum(max) <= maxWidth 时行为不变:富余全塞给最后一列,让表格铺满气泡。
    func testLooseFit_surplusGoesToLastColumn() {
        let md = """
        | A | B |
        |---|---|
        | 1 | 2 |
        """
        let layout = makeLayout(markdown: md, maxWidth: 400)
        XCTAssertEqual(layout.columnWidths.count, 2)
        XCTAssertEqual(layout.columnWidths.reduce(0, +), 400, accuracy: 0.5)
        // 最后一列拿走富余
        XCTAssertGreaterThan(layout.columnWidths[1], layout.columnWidths[0])
    }

    /// 空表不 crash。
    func testEmptyTable() {
        let theme = TranscriptTheme.default
        let builder = MarkdownAttributedBuilder(theme: theme.markdown)
        let empty = MarkdownTable(header: [], alignments: [], rows: [])
        let contents = TranscriptTableCellContents.make(table: empty, builder: builder)
        let layout = TranscriptTableLayout.make(contents: contents, theme: theme, maxWidth: 400)
        XCTAssertTrue(layout.columnWidths.isEmpty)
        XCTAssertTrue(layout.rowHeights.isEmpty)
        XCTAssertEqual(layout.totalWidth, 0)
        XCTAssertEqual(layout.totalHeight, 0)
    }

    /// 极窄 maxWidth < sum(min):等比压 min,不让表格溢出气泡。
    func testExtremeNarrow_clampedToMaxWidth() {
        let md = """
        | aaaaaaaaaa | bbbbbbbbbb |
        |---|---|
        | xxxxxxxxxx | yyyyyyyyyy |
        """
        let layout = makeLayout(markdown: md, maxWidth: 40)
        XCTAssertEqual(layout.columnWidths.count, 2)
        XCTAssertLessThanOrEqual(layout.columnWidths.reduce(0, +), 40.5)
    }

    /// 相同内容的列应该分到相同宽度。
    func testEqualContent_equalWidth() {
        let md = """
        | same | same |
        |------|------|
        | foo  | foo  |
        """
        let layout = makeLayout(markdown: md, maxWidth: 400)
        XCTAssertEqual(layout.columnWidths.count, 2)
        // 两列完全对称,但富余空间全给最后一列——所以第 2 列会更大。
        // 这里只验证 tight 情况:maxWidth 刚好等于 sum(max),两列相等。
        let contentsCellMax = TranscriptTableCellContents.make(
            table: {
                let doc = MarkdownDocument(parsing: md)
                for seg in doc.segments {
                    if case .table(let t) = seg { return t }
                }
                return MarkdownTable(header: [], alignments: [], rows: [])
            }(),
            builder: MarkdownAttributedBuilder(theme: TranscriptTheme.default.markdown))
        let maxSum = contentsCellMax.cellMaxWidths.flatMap { $0 }.max() ?? 0
        // 选一个刚好小于 2 * maxCell 的宽度,让分配进入"min 起步 + 按 max 分"分支;
        // 此时两列权重相同,宽度一致。
        let tight = maxSum * 2 - 10
        let theme = TranscriptTheme.default
        let layout2 = TranscriptTableLayout.make(
            contents: contentsCellMax, theme: theme, maxWidth: tight)
        XCTAssertEqual(layout2.columnWidths[0], layout2.columnWidths[1], accuracy: 0.5)
    }
}
