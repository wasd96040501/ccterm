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

    // MARK: - Ordered list markers have equal visual widths

    func testOrderedListSingleDigitMarkersShareWidth() {
        // "1." / "2." / "3." —— 用 SF Mono 后三者宽度必须相同，不再受
        // 数字→dot pair kerning 的影响。
        let out = build("""
        1. one
        2. two
        3. three
        """)
        let s = out.string as NSString
        let markerWidths = ["1.", "2.", "3."].map { marker -> CGFloat in
            let range = s.range(of: marker)
            XCTAssertNotEqual(range.location, NSNotFound)
            let sub = out.attributedSubstring(from: range)
            return sub.size().width
        }
        let first = markerWidths[0]
        for (i, w) in markerWidths.enumerated() {
            XCTAssertEqual(
                w, first, accuracy: 0.01,
                "marker[\(i)] width=\(w) vs baseline \(first) — digits must be tabular")
        }
    }

    func testOrderedList99vs100MaintainsRightTabStop() {
        // "99." / "100." 的 marker 宽度应随位数单调增长（mono font，3 chars vs
        // 4 chars），由于 right-align tab stop 会对齐到同一 dot 右缘——**内容**
        // 起点仍然一致。这里只能断言 marker 本身的递增性。
        let out = build("""
        99. a
        100. b
        """)
        let s = out.string as NSString
        let w99 = out.attributedSubstring(
            from: s.range(of: "99.")).size().width
        let w100 = out.attributedSubstring(
            from: s.range(of: "100.")).size().width
        XCTAssertLessThan(w99, w100, "4-char marker must be wider than 3-char")
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

    // MARK: - Nested list: leading whitespace trimmed

    func testNestedListFirstParagraphTrimsLeadingWhitespace() {
        // 模拟 source 含冗余前导空格的情况。直接用 builder 的 trim helper
        // 验证不变式——直接 parse 不一定能复现，取决于 swift-markdown 是否
        // 在 inline 里保留前导空格。
        let trimmed = MarkdownAttributedBuilder.trimLeadingWhitespace([
            .text("   inner"),
        ])
        guard case .text(let s) = trimmed.first else {
            return XCTFail("expected text inline, got \(trimmed)")
        }
        XCTAssertEqual(s, "inner")

        // 非 text 首元素不动
        let unchanged = MarkdownAttributedBuilder.trimLeadingWhitespace([
            .code("x"),
            .text("y"),
        ])
        if case .code(let c) = unchanged.first {
            XCTAssertEqual(c, "x")
        } else {
            XCTFail("non-text leading element should be preserved")
        }

        // 纯空白首元素被吞掉
        let dropped = MarkdownAttributedBuilder.trimLeadingWhitespace([
            .text("   "),
            .text("rest"),
        ])
        XCTAssertEqual(dropped.count, 1)
        if case .text(let s) = dropped.first {
            XCTAssertEqual(s, "rest")
        }
    }

    // MARK: - Task list: Unicode checkbox

    func testTaskListRendersUnicodeCheckboxes() {
        let out = build("""
        - [x] done
        - [ ] pending
        """)
        let s = out.string
        XCTAssertTrue(s.contains("☑"), "checked item must render U+2611")
        XCTAssertTrue(s.contains("☐"), "unchecked item must render U+2610")
        // 不应再出现 U+FFFC（NSTextAttachment 的 object replacement character）
        XCTAssertFalse(
            s.contains("\u{FFFC}"),
            "NSTextAttachment path is invalid under CoreText — must not emit U+FFFC")
    }
}
