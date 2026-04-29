import AppKit
import XCTest
@testable import ccterm

/// 覆盖 `TranscriptTextLayout` 的几何 / range 不变式。
///
/// 重点是两类隐患：
/// - 几何 fallback（y 在 gap 里、point 越界、空字串）
/// - range 反向输入（selectionRange 的 start/end 顺序无关、CTLine 返回 -1）
///
/// 测试覆盖的 bug 来源：`for upperRow in upperRow...lowerRow` 型崩溃——
/// 上游任何拿 CFIndex / rowIndex 的地方都要对负值 / 越界保持幂等。
@MainActor
final class TranscriptTextLayoutTests: XCTestCase {

    private func layout(_ s: String, width: CGFloat = 400) -> TranscriptTextLayout {
        let attr = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
        ])
        return TranscriptTextLayout.make(attributed: attr, maxWidth: width)
    }

    // MARK: - Empty / degenerate

    func testEmptyLayoutReturnsEmptySelectionAndRanges() {
        let l = TranscriptTextLayout.empty
        XCTAssertNil(l.characterIndex(at: .zero))
        XCTAssertEqual(l.selectionRange(from: .zero, to: CGPoint(x: 50, y: 10)),
                       NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(l.wordRange(at: .zero),
                       NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(l.paragraphRange(at: .zero),
                       NSRange(location: NSNotFound, length: 0))
    }

    func testZeroWidthReturnsEmpty() {
        let attr = NSAttributedString(string: "hi")
        let l = TranscriptTextLayout.make(attributed: attr, maxWidth: 0)
        XCTAssertEqual(l.totalHeight, 0)
        XCTAssertTrue(l.lines.isEmpty)
    }

    // MARK: - Selection range: reversed input & out-of-bounds

    func testSelectionRangeReversedPointsEqualsForward() {
        let l = layout("hello world")
        guard !l.lines.isEmpty else { return XCTFail("no lines") }
        let midY = l.lineRects[0].midY
        let forward = l.selectionRange(
            from: CGPoint(x: 0, y: midY),
            to: CGPoint(x: 60, y: midY))
        let backward = l.selectionRange(
            from: CGPoint(x: 60, y: midY),
            to: CGPoint(x: 0, y: midY))
        XCTAssertEqual(forward, backward)
        XCTAssertGreaterThan(forward.length, 0)
    }

    func testSelectionRangeWithPointFarLeftClampsGracefully() {
        // `CTLineGetStringIndexForPosition` 对 x << 0 返回 line start,
        // x >> line width 返回 line end。两点都远在左侧不应产生负 range。
        let l = layout("hello")
        guard !l.lines.isEmpty else { return XCTFail("no lines") }
        let midY = l.lineRects[0].midY
        let r = l.selectionRange(
            from: CGPoint(x: -1000, y: midY),
            to: CGPoint(x: -1000, y: midY))
        XCTAssertEqual(r.length, 0, "same point → empty range")
        // 断言没有 crash / 负 length —— range.location clamp 到 >= 0
        XCTAssertGreaterThanOrEqual(r.location, 0)
    }

    // MARK: - Word range

    func testWordRangeSelectsLatinWord() {
        let l = layout("hello world foo")
        guard !l.lines.isEmpty else { return XCTFail("no lines") }
        let midY = l.lineRects[0].midY
        // 点在 "world" 中间附近
        let approxX = CGFloat("hello ".count) * 7  // 粗估
        let r = l.wordRange(at: CGPoint(x: approxX, y: midY))
        XCTAssertNotEqual(r.location, NSNotFound)
        let picked = (l.attributed.string as NSString).substring(with: r)
        // 选中的应是一个词，不是单字符或整句——至少 >= 2 chars 且不含空格
        XCTAssertGreaterThanOrEqual(picked.count, 2)
        XCTAssertFalse(picked.contains(" "))
    }

    func testWordRangeAtFarPointReturnsNotFound() {
        let l = layout("hi")
        // y 远超 layout 顶端 → findLineIndex clamp 到第一行，characterIndex 可能
        // 返回 line start 或 kCFNotFound；必须不 crash + 不返回负 range。
        let r = l.wordRange(at: CGPoint(x: -1000, y: -1000))
        // 允许返回 NSNotFound 或一个 valid range；主要断言不崩 + location 非负。
        if r.location != NSNotFound {
            XCTAssertGreaterThanOrEqual(r.location, 0)
            XCTAssertGreaterThan(r.length, 0)
        }
    }

    // MARK: - Paragraph range

    func testParagraphRangeSpansNewlineBoundaries() {
        let l = layout("first line\nsecond line\nthird")
        guard l.lines.count >= 2 else { return XCTFail("expected ≥2 lines") }
        let y = l.lineRects[1].midY
        let r = l.paragraphRange(at: CGPoint(x: 10, y: y))
        XCTAssertNotEqual(r.location, NSNotFound)
        let picked = (l.attributed.string as NSString).substring(with: r)
        XCTAssertTrue(picked.contains("second"))
        XCTAssertFalse(picked.contains("first"))
        XCTAssertFalse(picked.contains("third"))
    }

    // MARK: - Line-index gap fallback

    func testFindLineIndexInGapPicksNearestLine() {
        // 构造有明显 lineSpacing 的 paragraph style。连续两行中间人为选个 y
        // 落在行间 gap，旧实现会 fall-through 返回最后一行导致选中跳变。
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 12
        let attr = NSMutableAttributedString(string: "line one\nline two")
        attr.addAttribute(.font,
                          value: NSFont.systemFont(ofSize: 13),
                          range: NSRange(location: 0, length: attr.length))
        attr.addAttribute(.paragraphStyle,
                          value: style,
                          range: NSRange(location: 0, length: attr.length))
        let l = TranscriptTextLayout.make(attributed: attr, maxWidth: 400)
        guard l.lineRects.count >= 2 else { return XCTFail("need ≥2 lines") }
        // 在两行之间的 gap 中心取点
        let gapY = (l.lineRects[0].maxY + l.lineRects[1].minY) / 2
        let idx = l.characterIndex(at: CGPoint(x: 5, y: gapY))
        XCTAssertNotNil(idx)
        // 不能跳到 layout 最末（那会让拖选经过 gap 时瞬间选到文末）
        let totalLen = CFIndex(attr.length)
        XCTAssertLessThan(idx!, totalLen,
                          "gap hit must not collapse to end-of-text")
    }
}
