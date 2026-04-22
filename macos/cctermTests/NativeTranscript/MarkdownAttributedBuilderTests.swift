import AppKit
import XCTest
@testable import ccterm

/// 覆盖 `MarkdownAttributedBuilder` 的渲染不变式——列表对齐、inline code 对称、
/// 嵌套 trim、任务列表 checkbox 字形。
///
/// 这里只断言**结构不变式**（字串 / 字形 / 宽度单调），不做像素对比——
/// SF Pro / SF Mono 不同机器下 advance 有微差，绝对值断言会飘。
@MainActor
final class MarkdownAttributedBuilderTests: XCTestCase {

    private func build(_ src: String) -> NSAttributedString {
        let doc = MarkdownDocument(parsing: src)
        let builder = MarkdownAttributedBuilder(theme: MarkdownTheme())
        guard case .markdown(let blocks) = doc.segments.first else {
            XCTFail("expected markdown segment, got \(doc.segments.first as Any)")
            return NSAttributedString()
        }
        return builder.build(blocks: blocks)
    }

    /// List 走专门的 ``TranscriptListContents`` 路径（marker 独立、不掺入正文
    /// 可选文本流），而不是塞到一个 NSAttributedString 里。下面的 list 断言
    /// 都走这个路径。
    private func buildList(_ src: String) -> TranscriptListContents {
        let doc = MarkdownDocument(parsing: src)
        let theme = MarkdownTheme()
        let builder = MarkdownAttributedBuilder(theme: theme)
        guard case .list(let list) = doc.segments.first else {
            XCTFail("expected list segment, got \(doc.segments.first as Any)")
            return TranscriptListContents(
                ordered: false,
                markerColumnWidth: 0,
                markerContentGap: 0,
                items: [])
        }
        return TranscriptListContents.make(list: list, theme: theme, builder: builder)
    }

    // MARK: - Ordered list markers have equal visual widths

    /// Convenience: 拿到 text marker 的排版宽度。checkbox 走固定边长不在这里。
    private func textMarkerWidth(_ m: MarkdownListMarker?) -> CGFloat {
        guard case .text(let attr) = m else { return 0 }
        return ceil(attr.size().width)
    }

    func testOrderedListSingleDigitMarkersShareWidth() {
        // "1." / "2." / "3." —— SF Mono 下三者宽度必须相同，不再受数字→dot
        // pair kerning 的影响。
        let contents = buildList("""
        1. one
        2. two
        3. three
        """)
        let widths = contents.items.map { textMarkerWidth($0.marker) }
        XCTAssertEqual(widths.count, 3)
        let first = widths[0]
        for (i, w) in widths.enumerated() {
            XCTAssertEqual(
                w, first, accuracy: 0.01,
                "marker[\(i)] width=\(w) vs baseline \(first) — digits must be tabular")
        }
    }

    func testOrderedList99vs100SharesMarkerColumnWidth() {
        // "99." / "100." marker 宽度随位数单调递增。layout 层把所有 item 的
        // marker 右对齐到 markerColumnWidth（= max over items），所以"."在
        // 同一列；正文起点 (= markerColumnWidth + gap) 对所有 item 一致。
        let contents = buildList("""
        99. a
        100. b
        """)
        XCTAssertEqual(contents.items.count, 2)
        let w99 = textMarkerWidth(contents.items[0].marker)
        let w100 = textMarkerWidth(contents.items[1].marker)
        XCTAssertLessThan(w99, w100, "4-char marker must be wider than 3-char")
        XCTAssertEqual(
            contents.markerColumnWidth, w100, accuracy: 0.01,
            "markerColumnWidth must equal the widest item marker width")
    }

    // MARK: - Inline code: spacer symmetry

    func testInlineCodeHasBalancedRunDelegateSpacers() {
        // LEFT 和 RIGHT 两侧都应插入 `InlineSpacer`（U+FFFC + CTRunDelegate），
        // 不再用 `.kern` hack。要求：
        // - 字串里有两个 U+FFFC
        // - 两个 U+FFFC 都带 CTRunDelegate attribute（独立 CTRun）
        // - 两个 spacer 的 advance 必须一致——验 CTRunDelegate.getWidth 回调
        //   返回相同的 CGFloat。
        let out = build("a `c` b")
        let s = out.string
        let joinerCount = s.filter { $0 == "\u{FFFC}" }.count
        XCTAssertEqual(joinerCount, 2, "inline code must have spacer on both sides")

        // 在原 NSAttributedString 上枚举 CTRunDelegate attribute——不依赖
        // CTLine 排版后的 run 划分（CoreText 不会把 delegate 透出到
        // CTRunGetAttributes，但 attribute 本来就在 source 上）。InlineSpacer
        // 把宽度存在 CTRunDelegate 的 refCon 里，验证它能取回且左右一致。
        let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
        let ns = out.string as NSString
        var spacerWidths: [CGFloat] = []
        out.enumerateAttribute(delegateKey,
                               in: NSRange(location: 0, length: out.length),
                               options: []) { value, range, _ in
            guard let v = value else { return }
            // 只看 U+FFFC——把 attachment 之类其它 delegate 用法排除掉。
            guard ns.substring(with: range).contains("\u{FFFC}") else { return }
            let delegate = v as! CTRunDelegate
            let refCon = CTRunDelegateGetRefCon(delegate)
            spacerWidths.append(refCon.assumingMemoryBound(to: CGFloat.self).pointee)
        }
        XCTAssertEqual(spacerWidths.count, 2,
                       "both spacers must carry CTRunDelegate on U+FFFC")
        if spacerWidths.count >= 2 {
            XCTAssertEqual(spacerWidths[0], spacerWidths[1], accuracy: 0.01,
                           "left and right spacers must share advance width")
            XCTAssertGreaterThan(spacerWidths[0], 0, "spacer advance must be positive")
            // Visible external gap = spacer.width - chipPadding. Spacer must
            // overshoot by chipPadding so the chip's drawn rect (which extends
            // chipPadding past its glyphs) doesn't eat the requested gap.
            // This regression guards against re-introducing the "gap = 6 ⇒ visible 2"
            // bug where the spacer was sized to the visible gap directly.
            let theme = MarkdownTheme()
            XCTAssertEqual(
                spacerWidths[0],
                theme.inlineCodeOuterGap + theme.inlineCodeHPadding,
                accuracy: 0.01,
                "spacer width must compensate for chip padding")
        }
    }

    /// 端到端验证：chip 旁边的 next 字符的实际 layout 位置必须在 chip 外缘之外
    /// 至少 `inlineCodeOuterGap` 点。这个测试是上面 width 断言的"行为版"，
    /// 直接跑 CTLine 排版，避免我们再次记错 padding 几何。
    func testInlineCodeChipLeavesVisibleExternalGap() {
        let out = build("a `c` b")
        let line = CTLineCreateWithAttributedString(out)
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]

        // chip run = 唯一带 inlineCodeBackground attribute 的 run
        var chipRun: CTRun?
        for run in runs {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            if attrs[NSAttributedString.Key.inlineCodeBackground] != nil {
                chipRun = run
                break
            }
        }
        guard let chip = chipRun else { return XCTFail("no chip run found") }

        // chip glyph 0 的 x 位置 + chip 总 advance = chip 末 glyph 末位
        var firstPos = CGPoint.zero
        CTRunGetPositions(chip, CFRange(location: 0, length: 1), &firstPos)
        let chipAdvance = CTRunGetTypographicBounds(chip, CFRange(location: 0, length: 0), nil, nil, nil)
        let chipLastGlyphEnd = firstPos.x + CGFloat(chipAdvance)

        // chip 之后下一个 run 的 first glyph x
        var nextRun: CTRun?
        var foundChip = false
        for run in runs {
            if foundChip {
                // skip spacer (zero glyph or U+FFFC run) — find the next run with visible glyphs
                let r = CTRunGetStringRange(run)
                if r.length > 0 {
                    let s = (out.string as NSString).substring(
                        with: NSRange(location: r.location, length: r.length))
                    if s != "\u{FFFC}" { nextRun = run; break }
                }
            }
            if run === chip { foundChip = true }
        }
        guard let next = nextRun else { return XCTFail("no run after chip") }
        var nextPos = CGPoint.zero
        CTRunGetPositions(next, CFRange(location: 0, length: 1), &nextPos)

        let theme = MarkdownTheme()
        let chipRightEdge = chipLastGlyphEnd + theme.inlineCodeHPadding
        let visibleGap = nextPos.x - chipRightEdge
        XCTAssertEqual(
            visibleGap, theme.inlineCodeOuterGap, accuracy: 0.5,
            "visible external gap must equal inlineCodeOuterGap "
            + "(got \(visibleGap), expected \(theme.inlineCodeOuterGap))")
    }

    // MARK: - Nested list: marker stays outside selectable text flow

    /// 内容只含正文（paragraph）的 NSAttributedString，marker 不在里面。
    /// 这是 "nested item 前面多一段可选空白" 的回归守护：过去 builder 会把
    /// `"\t" + marker + "\t"` 拼进 attributed string，nested 层因为
    /// CoreText/TextKit 对 tab stop 坐标系解释不同，行首多出一段可选的 `\t`
    /// 宽度。独立 marker 路径彻底绕开，attributed string 里只剩正文。
    func testNestedItemContentHasNoMarkerOrLeadingTab() {
        let contents = buildList("""
        - outer
          - inner
        """)
        XCTAssertEqual(contents.items.count, 1)
        guard let outer = contents.items.first,
              case .text(let outerAttr) = outer.content.first else {
            return XCTFail("expected outer item with text content")
        }
        XCTAssertEqual(outerAttr.string, "outer")
        XCTAssertFalse(outerAttr.string.contains("\t"),
                       "tab characters must not leak into item content")
        XCTAssertFalse(outerAttr.string.contains("•"),
                       "bullet marker must not leak into item content")

        // 第二个 content 应该是递归的 nested list
        guard outer.content.count >= 2,
              case .list(let nested) = outer.content[1] else {
            return XCTFail("expected nested list as second content block")
        }
        XCTAssertEqual(nested.items.count, 1)
        guard case .text(let innerAttr) = nested.items[0].content.first else {
            return XCTFail("expected nested item text content")
        }
        XCTAssertEqual(innerAttr.string, "inner")
        XCTAssertFalse(innerAttr.string.contains("\t"))
        XCTAssertFalse(innerAttr.string.contains("•"))
    }

    // MARK: - Task list: checkbox marker

    func testTaskListMarkersAreCheckboxVariant() {
        // Checkbox 走独立 marker 类型（不是 `.text` 带 "☑"/"☐" 字形）——CoreText
        // 侧 CGPath 自绘、SwiftUI 侧 SF Symbol。绕开 SF Pro 里 U+2611 和
        // U+2610 glyph 设计不对称（checked 方框更粗更大）的问题。
        let contents = buildList("""
        - [x] done
        - [ ] pending
        """)
        XCTAssertEqual(contents.items.count, 2)
        guard case .checkbox(let c0) = contents.items[0].marker else {
            return XCTFail("expected .checkbox marker for first item")
        }
        guard case .checkbox(let c1) = contents.items[1].marker else {
            return XCTFail("expected .checkbox marker for second item")
        }
        XCTAssertTrue(c0, "[x] item must be checked")
        XCTAssertFalse(c1, "[ ] item must be unchecked")
    }
}
