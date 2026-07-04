import CoreGraphics
import CoreText
import Foundation

/// Per-block CoreText typeset result. Foundation-only (no AppKit / NSView /
/// NSColor). `make(for:width:)` runs the CoreText frameset synchronously;
/// the result carries the total row `height`, the paragraph rect, and the
/// framesetter itself (retained so `draw(in:origin:)` can rasterise into
/// any `CGContext` without re-typesetting).
///
/// `@unchecked Sendable` because `CTFramesetter` isn't `Sendable`-annotated
/// upstream. It is a value-type CF handle that is safe to hand across
/// actors as long as writes happen on one thread at a time — which we
/// guarantee: `make` is either called on the main actor (Phase 1) or in
/// `Task.detached` (Phase 2), and the resulting `RowLayout` becomes
/// immutable the moment `make` returns.
public final class T3RowLayout: @unchecked Sendable {

    public let height: CGFloat
    public let width: CGFloat
    public let attributed: NSAttributedString
    public let framesetter: CTFramesetter
    public let bounds: CGRect

    private init(
        height: CGFloat,
        width: CGFloat,
        attributed: NSAttributedString,
        framesetter: CTFramesetter,
        bounds: CGRect
    ) {
        self.height = height
        self.width = width
        self.attributed = attributed
        self.framesetter = framesetter
        self.bounds = bounds
    }

    /// Typeset one block into an immutable layout. Sync, thread-safe when
    /// called with an unshared `Block`. Runs off-main safely — CoreText
    /// itself is thread-safe for these operations.
    public static func make(for block: T3Block, width: CGFloat) -> T3RowLayout {
        let insetH: CGFloat = 20
        let insetV: CGFloat = 8
        let contentWidth = max(width - insetH * 2, 1)

        let attributed = attributedString(for: block, contentWidth: contentWidth)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)

        let unbounded = CGSize(width: contentWidth, height: .greatestFiniteMagnitude)
        var fitRange = CFRange(location: 0, length: 0)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            nil,
            unbounded,
            &fitRange
        )
        let textHeight = ceil(suggested.height)
        let rowHeight = max(textHeight + insetV * 2, 22)
        let bounds = CGRect(
            x: insetH,
            y: insetV,
            width: contentWidth,
            height: textHeight
        )
        return T3RowLayout(
            height: rowHeight,
            width: width,
            attributed: attributed,
            framesetter: framesetter,
            bounds: bounds
        )
    }

    // MARK: - Attributed string synthesis

    private static let assistantFont =
        CTFontCreateWithName("SFPro-Regular" as CFString, 13, nil)
    private static let userFont =
        CTFontCreateWithName("SFPro-Regular" as CFString, 13, nil)
    private static let systemFont =
        CTFontCreateWithName("SFPro-Regular" as CFString, 11, nil)
    private static let codeFont =
        CTFontCreateWithName("Menlo" as CFString, 12, nil)
    private static let toolNameFont =
        CTFontCreateWithName("SFMono-Semibold" as CFString, 12, nil)

    private static func attributedString(
        for block: T3Block, contentWidth: CGFloat
    )
        -> NSAttributedString
    {
        switch block.kind {
        case .assistantText(let s):
            return string(s, font: assistantFont, color: labelColor)
        case .userBubble(let text, let attachments):
            let head = attachments.isEmpty ? "" : "[\(attachments.count) image] "
            return string(head + text, font: userFont, color: labelColor)
        case .system(let s):
            return string(s, font: systemFont, color: secondaryLabelColor)
        case .codeBlock(let lang, let code):
            let header = lang.map { "› \($0)\n" } ?? ""
            return string(header + code, font: codeFont, color: labelColor)
        case .toolCall(let call):
            return toolCallString(call)
        case .toolGroup(let calls):
            let combined = NSMutableAttributedString()
            for (i, call) in calls.enumerated() {
                if i > 0 { combined.append(NSAttributedString(string: "\n")) }
                combined.append(toolCallString(call))
            }
            return combined
        }
    }

    private static func toolCallString(_ call: T3Block.ToolCall) -> NSAttributedString {
        let out = NSMutableAttributedString()
        out.append(string("● \(call.name)", font: toolNameFont, color: labelColor))
        out.append(string("  \(call.inputSummary)", font: userFont, color: secondaryLabelColor))
        if let output = call.output {
            let previewText = truncate(output.text, to: 400)
            out.append(NSAttributedString(string: "\n"))
            out.append(
                string(
                    previewText, font: codeFont,
                    color: output.isError ? errorLabelColor : secondaryLabelColor))
        }
        return out
    }

    private static func string(_ s: String, font: CTFont, color: CGColor) -> NSAttributedString {
        // CoreText attribute keys — deliberately not AppKit's
        // `.font` / `.foregroundColor` so this file stays Foundation-only.
        // Both bridge to the same CFAttributedString CoreText draws.
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return NSAttributedString(string: s, attributes: attrs)
    }

    private static func truncate(_ s: String, to n: Int) -> String {
        guard s.count > n else { return s }
        let idx = s.index(s.startIndex, offsetBy: n)
        return String(s[..<idx]) + "…"
    }

    // Fallback fixed colors — CGColor is Foundation-adjacent (Quartz).
    // The view layer overrides these when it draws, so light/dark switches
    // still work; these are only used if the cell draws attributed strings
    // that were baked without a color override at typeset time.
    private static let labelColor = CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
    private static let secondaryLabelColor = CGColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1)
    private static let errorLabelColor = CGColor(red: 0.85, green: 0.2, blue: 0.2, alpha: 1)
}
