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

    // MARK: - Inline code: joiner symmetry

    func testInlineCodeHasBalancedWordJoiners() {
        // LEFT 和 RIGHT 两侧都应插入 U+2060 + kern，而不是只在 RIGHT 一侧。
        let out = build("a `c` b")
        let s = out.string
        let joinerCount = s.filter { $0 == "\u{2060}" }.count
        XCTAssertEqual(joinerCount, 2, "inline code must have joiner on both sides")
        // 两个 joiner 都必须带相同的 kern。
        let ns = out.string as NSString
        var kerns: [CGFloat] = []
        out.enumerateAttribute(.kern, in: NSRange(location: 0, length: out.length),
                               options: []) { value, range, _ in
            let sub = ns.substring(with: range)
            guard sub.contains("\u{2060}") else { return }
            if let k = value as? NSNumber {
                kerns.append(CGFloat(truncating: k))
            }
        }
        XCTAssertGreaterThanOrEqual(kerns.count, 2)
        if kerns.count >= 2 {
            XCTAssertEqual(kerns[0], kerns[1], "left and right joiners must share kern value")
        }
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
