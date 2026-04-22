import AppKit
import XCTest
@testable import ccterm

/// 覆盖 2026-04 两项改动：
/// 1. 超链接 attribute 确实挂在 `.link` 上（`TranscriptController.linkURL`
///    hit-test 的底层保证）
/// 2. Markdown 表格 cell 作为可选中 region（`TranscriptTableLayout.cellContentFrames`
///    与 cells 一一对应，是 Cmd-C 拼接的基础）
///
/// 刻意避免直接构造 `@MainActor` 的 `AssistantMarkdownRow` 实例——Swift 6 的
/// MainActor-class deinit 与 XCTest autoreleasepool 交互存在 libmalloc abort
/// 问题。改为通过 builder / struct 做等价断言。
@MainActor
final class TranscriptLinkAndTableCopyTests: XCTestCase {

    // MARK: - 1. Link attribute carried through builder

    /// `MarkdownAttributedBuilder` 必须把 `.link` attribute 贴到 link 文字上,
    /// TranscriptController.linkURL 的底层 hit-test 依赖这个 attribute。
    func testMarkdownBuilder_linkCarriesURLAttribute() {
        let source = "See [docs](https://swift.org) for more."
        let doc = MarkdownDocument(parsing: source)
        let builder = MarkdownAttributedBuilder(theme: .default)
        var attr = NSAttributedString()
        for seg in doc.segments {
            if case .markdown(let blocks) = seg {
                attr = builder.build(blocks: blocks)
                break
            }
        }
        XCTAssertGreaterThan(attr.length, 0)
        var foundURL: String?
        attr.enumerateAttribute(.link, in: NSRange(location: 0, length: attr.length)) { value, _, _ in
            if let s = value as? String { foundURL = s }
            if let u = value as? URL { foundURL = u.absoluteString }
        }
        XCTAssertEqual(foundURL, "https://swift.org")
    }

    // MARK: - 2. Table cells are laid out & individually selectable

    /// `TranscriptTableLayout.cellContentFrames` 与 `cells` 一一对应、形状一致,
    /// 并且 frames 单调不重叠——Cmd-C 按 (row, col) 顺序拼接能拿到自然顺序。
    func testTableLayout_cellFramesMatchCellsAndAreMonotonic() {
        let source = """
        | A | B |
        | - | - |
        | 1 | 2 |
        | 3 | 4 |
        """
        let doc = MarkdownDocument(parsing: source)
        var table: MarkdownTable?
        for seg in doc.segments {
            if case .table(let t) = seg { table = t; break }
        }
        guard let table else { return XCTFail("no table segment parsed") }

        let theme = TranscriptTheme(markdown: .default)
        let builder = MarkdownAttributedBuilder(theme: theme.markdown)
        let layout = TranscriptTableLayout.make(
            table: table, builder: builder, theme: theme, maxWidth: 400)

        // header + 2 body rows × 2 cols = 6 cells
        XCTAssertEqual(layout.cells.count, 3)
        XCTAssertEqual(layout.cells.allSatisfy { $0.count == 2 }, true)

        let frames = layout.cellContentFrames
        XCTAssertEqual(frames.count, layout.cells.count)
        for (r, rowFrames) in frames.enumerated() {
            XCTAssertEqual(rowFrames.count, layout.cells[r].count)
        }
        // 同 row 内 X 单调递增；跨 row Y 单调递增。
        for r in 0..<frames.count {
            for c in 1..<frames[r].count {
                XCTAssertLessThan(frames[r][c - 1].minX, frames[r][c].minX)
            }
            if r > 0 {
                XCTAssertLessThanOrEqual(frames[r - 1][0].maxY, frames[r][0].minY + 0.01)
            }
        }
    }

    /// cellContentFrames 是空表时的 no-crash 保证——零列零行时 iteration 安全。
    func testTableLayout_emptyTableYieldsEmptyFrames() {
        let theme = TranscriptTheme(markdown: .default)
        let builder = MarkdownAttributedBuilder(theme: theme.markdown)
        let empty = MarkdownTable(header: [], alignments: [], rows: [])
        let layout = TranscriptTableLayout.make(
            table: empty, builder: builder, theme: theme, maxWidth: 400)
        XCTAssertTrue(layout.cellContentFrames.isEmpty)
        XCTAssertEqual(layout.totalWidth, 0)
        XCTAssertEqual(layout.totalHeight, 0)
    }
}
