import AppKit
import CoreText
import XCTest
@testable import ccterm

/// 端到端验证 `InlineSpacer`：CTLine 实际排版后，spacer 必须给行宽贡献它声明的
/// advance。
///
/// 之前 `MarkdownAttributedBuilderTests` 只验证 attribute 挂上去——但
/// CoreText 对 `Default_Ignorable_Code_Point=Yes` 的字符（如 U+FFFC
/// WORD JOINER）会直接 elide，连带挂在它上面的 CTRunDelegate / .kern 都不会
/// 被 layout 用上。所以"attribute 在"≠"layout 用了"，必须实际跑一遍 layout
/// 才能验。
@MainActor
final class InlineSpacerTests: XCTestCase {

    /// 加 spacer 之后 CTLine 行宽必须严格大于不加 spacer 时——增量 ≈ spacer width。
    func testSpacerActuallyAddsAdvanceToCTLine() {
        let font = NSFont.systemFont(ofSize: 14)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]

        let plain = NSAttributedString(string: "ab", attributes: attrs)
        let plainWidth = lineWidth(plain)

        let withSpacer = NSMutableAttributedString()
        withSpacer.append(NSAttributedString(string: "a", attributes: attrs))
        withSpacer.append(InlineSpacer.attributedString(width: 20))
        withSpacer.append(NSAttributedString(string: "b", attributes: attrs))
        let spacedWidth = lineWidth(withSpacer)

        let delta = spacedWidth - plainWidth
        XCTAssertEqual(
            delta, 20, accuracy: 1.0,
            "spacer must add ~20pt to line width "
            + "(plain=\(plainWidth), spaced=\(spacedWidth), delta=\(delta))")
    }

    /// 多次叠加：n 个 spacer 应该累加贡献 n × width。
    func testMultipleSpacersAccumulateAdvance() {
        let font = NSFont.systemFont(ofSize: 14)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]

        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: "a", attributes: attrs))
        for _ in 0..<5 {
            s.append(InlineSpacer.attributedString(width: 10))
        }
        s.append(NSAttributedString(string: "b", attributes: attrs))

        let plain = NSAttributedString(string: "ab", attributes: attrs)
        let delta = lineWidth(s) - lineWidth(plain)
        XCTAssertEqual(delta, 50, accuracy: 1.0,
                       "5 × 10pt spacers must add ~50pt (got \(delta))")
    }

    /// 0/负宽度：不应该崩，也不应增宽。
    func testZeroWidthSpacerIsNoOp() {
        let font = NSFont.systemFont(ofSize: 14)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let s = NSMutableAttributedString(string: "a", attributes: attrs)
        s.append(InlineSpacer.attributedString(width: 0))
        s.append(NSAttributedString(string: "b", attributes: attrs))

        let plain = NSAttributedString(string: "ab", attributes: attrs)
        XCTAssertEqual(lineWidth(s), lineWidth(plain), accuracy: 1.0)
    }

    private func lineWidth(_ a: NSAttributedString) -> Double {
        let line = CTLineCreateWithAttributedString(a)
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }
}
