import AppKit
import XCTest
@testable import ccterm

/// ``TranscriptListLayout`` 的几何不变式：marker 列宽 / 内容起点 / 嵌套
/// 累加 / DFS 顺序。这里只断言**结构性等式和单调性**，不对具体像素值做硬编码——
/// 字体 advance 在不同机器下有微差，ccterm 的其它 layout 测试都走这个路子。
@MainActor
final class TranscriptListLayoutTests: XCTestCase {

    private let theme = TranscriptTheme.default
    private let maxWidth: CGFloat = 400

    // MARK: - Helpers

    private func makeLayout(_ src: String) -> TranscriptListLayout {
        let doc = MarkdownDocument(parsing: src)
        guard case .list(let list) = doc.segments.first else {
            XCTFail("expected list segment, got \(doc.segments.first as Any)")
            return TranscriptListLayout.make(
                contents: TranscriptListContents(
                    ordered: false, markerColumnWidth: 0,
                    markerContentGap: 0, items: []),
                theme: theme,
                maxWidth: maxWidth)
        }
        let builder = MarkdownAttributedBuilder(theme: theme.markdown)
        let contents = TranscriptListContents.make(
            list: list, theme: theme.markdown, builder: builder)
        return TranscriptListLayout.make(
            contents: contents, theme: theme, maxWidth: maxWidth)
    }

    // MARK: - Geometry

    func testContentOriginEqualsMarkerColumnPlusGap() {
        let layout = makeLayout("- item")
        XCTAssertEqual(
            layout.contentOriginX,
            layout.markerColumnWidth + layout.markerContentGap,
            accuracy: 0.01,
            "contentOriginX must be markerColumnWidth + markerContentGap")
    }

    func testMarkerRightAlignedToMarkerColumn() {
        // 三个 bullet item——所有 markerRightX 应等于 markerColumnWidth
        // （marker 右边缘都对齐到 marker 列的右边）。
        let layout = makeLayout("""
        - a
        - b
        - c
        """)
        XCTAssertEqual(layout.items.count, 3)
        for (i, item) in layout.items.enumerated() {
            XCTAssertEqual(
                item.markerRightX, layout.markerColumnWidth, accuracy: 0.01,
                "item[\(i)] markerRightX must equal markerColumnWidth")
        }
    }

    func testItemTopYIsMonotonicAndSpacedByL3Item() {
        // 每个 item 的 topY 单调递增，相邻 items 间距 = theme.l3Item。
        let layout = makeLayout("""
        - a
        - b
        - c
        """)
        XCTAssertEqual(layout.items.count, 3)
        let tops = layout.items.map(\.topY)
        XCTAssertEqual(tops[0], 0, accuracy: 0.01, "first item sits at topY=0")
        // 相邻差 = 上一个 item.height + l3Item。
        for i in 1..<tops.count {
            let prev = layout.items[i - 1]
            let expected = prev.topY + prev.height + theme.markdown.l3Item
            XCTAssertEqual(
                tops[i], expected, accuracy: 0.01,
                "item[\(i)] topY must be prev.topY + prev.height + l3Item")
        }
    }

    func testTotalHeightCoversLastItem() {
        let layout = makeLayout("""
        - a
        - b
        """)
        guard let last = layout.items.last else { return XCTFail("no items") }
        XCTAssertEqual(
            layout.totalHeight, last.topY + last.height, accuracy: 0.01,
            "totalHeight must reach the bottom of the last item")
    }

    func testMarkerBaselineAlignsToFirstTextBaseline() {
        // 正文 TranscriptTextLayout 的第一行 baseline 应与 marker baseline 一致——
        // marker 和首行字在视觉上同一行。
        let layout = makeLayout("- single-line item")
        guard let item = layout.items.first,
              case .text(let textLayout, let origin) = item.contents.first,
              let firstLineOrigin = textLayout.lineOrigins.first else {
            return XCTFail("expected text content with at least one line")
        }
        // textLayout 坐标系内 line baseline 相对 layout 原点 = lineOrigins[0].y。
        // 加 origin.y（textLayout 在 list 坐标里的原点）→ list 坐标下的 baseline。
        let expectedBaseline = origin.y + firstLineOrigin.y
        XCTAssertEqual(
            item.markerBaselineY, expectedBaseline, accuracy: 0.01,
            "marker baseline must align with first line baseline of item text")
    }

    // MARK: - Nested

    func testNestedListOriginSitsAtContentColumn() {
        // nested list 的 origin.x = 外层 contentOriginX（正文起点列）。
        let layout = makeLayout("""
        - outer
          - inner
        """)
        guard let outer = layout.items.first else { return XCTFail("no outer") }
        // outer 的第二个 content 应该是 nested list
        guard outer.contents.count >= 2,
              case .list(_, let nestedOrigin) = outer.contents[1] else {
            return XCTFail("expected nested list as second content")
        }
        XCTAssertEqual(
            nestedOrigin.x, layout.contentOriginX, accuracy: 0.01,
            "nested list origin.x must equal outer contentOriginX")
    }

    func testNestedListHeightAccumulatesIntoOuterItemHeight() {
        let layout = makeLayout("""
        - outer
          - inner a
          - inner b
        """)
        guard let outer = layout.items.first else { return XCTFail("no outer") }

        // 拆出正文 text 和 nested list 的高度
        var textH: CGFloat = 0
        var nestedH: CGFloat = 0
        for content in outer.contents {
            switch content {
            case .text(let t, _): textH = t.totalHeight
            case .list(let n, _): nestedH = n.totalHeight
            }
        }
        // outer item 高度 = text 高 + l3Item（block 内间距） + nested 高
        let expected = textH + theme.markdown.l3Item + nestedH
        XCTAssertEqual(
            outer.height, expected, accuracy: 0.01,
            "outer item height must sum text + intra-item gap + nested height")
    }

    func testMarkerBaselineAlignsToNestedFirstWhenNoText() {
        // 如果 item 的第一个 content 不是正文而是 nested list（罕见），
        // 外层 marker baseline 应对齐到 nested 的第一个 marker baseline——
        // 而不是退化到 item top。
        //
        // 构造这种形态需要手搓 MarkdownList（直接 parse 很难生成一个 item
        // 的首 content 就是 list，因为 list item 通常至少有一段 paragraph）。
        let inner = MarkdownList(
            ordered: false, startIndex: nil,
            items: [MarkdownListItem(checkbox: nil, content: [
                .paragraph([.text("inner")]),
            ])])
        let outer = MarkdownList(
            ordered: false, startIndex: nil,
            items: [MarkdownListItem(checkbox: nil, content: [
                .list(inner),
            ])])

        let builder = MarkdownAttributedBuilder(theme: theme.markdown)
        let contents = TranscriptListContents.make(
            list: outer, theme: theme.markdown, builder: builder)
        let layout = TranscriptListLayout.make(
            contents: contents, theme: theme, maxWidth: maxWidth)

        guard let outerItem = layout.items.first,
              case .list(let nestedLayout, let nestedOrigin) = outerItem.contents.first,
              let innerItem = nestedLayout.items.first else {
            return XCTFail("expected outer item with nested list")
        }
        // inner.markerBaselineY 是 list 坐标（nested layout 自身坐标系）。
        // 外层 marker 对齐的是 "innerItem.markerBaselineY offset 到外层坐标"，
        // 即 nestedOrigin.y + innerItem.markerBaselineY。
        let expected = nestedOrigin.y + innerItem.markerBaselineY
        XCTAssertEqual(
            outerItem.markerBaselineY, expected, accuracy: 0.01,
            "when item's first content is a nested list, outer marker baseline "
            + "must align with the nested list's first marker baseline")
    }

    // MARK: - flattenedTexts DFS order

    func testFlattenedTextsVisitsOuterBeforeNestedBeforeNextOuter() {
        // DFS 顺序：outer-1 text → (outer-1 的 nested items) → outer-2 text。
        // draw() 和 selectableRegions 共用这个 index，两路必须一致。
        let layout = makeLayout("""
        - outer 1
          - inner 1a
          - inner 1b
        - outer 2
        """)
        let flat = layout.flattenedTexts()

        // 4 段 text：outer1 / inner1a / inner1b / outer2
        XCTAssertEqual(flat.count, 4)
        for (pos, entry) in flat.enumerated() {
            XCTAssertEqual(
                entry.index, pos,
                "flattened index must match DFS position")
        }

        // 通过 measuredWidth 约束不强，改用 lineOrigins[0] 在 list 坐标下
        // 的 y 单调性：DFS 顺序下 y 应该递增。
        let ys = flat.map { entry -> CGFloat in
            let first = entry.layout.lineOrigins.first?.y ?? 0
            return entry.originInList.y + first
        }
        for i in 1..<ys.count {
            XCTAssertLessThan(
                ys[i - 1], ys[i],
                "flattened order y=\(ys[i - 1]) must precede y=\(ys[i])")
        }
    }

    func testFlattenedTextsSkipsMarkersOnly() {
        // 空 list 产出空扁平流。
        let empty = TranscriptListLayout.make(
            contents: TranscriptListContents(
                ordered: false, markerColumnWidth: 0,
                markerContentGap: 0, items: []),
            theme: theme,
            maxWidth: maxWidth)
        XCTAssertTrue(empty.flattenedTexts().isEmpty)
    }
}
