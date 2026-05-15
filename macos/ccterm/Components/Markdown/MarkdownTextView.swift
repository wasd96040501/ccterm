import AppKit
import SwiftUI

/// Renders a prebuilt `NSAttributedString` for a single `.markdown` segment
/// using TextKit 1 + `NSTextView`. Read-only, selectable, link-aware.
///
/// Sizing follows the standard AppKit-in-SwiftUI pattern:
/// `intrinsicContentSize` reports `(noIntrinsicMetric, usedHeight)` so the
/// view accepts whatever width SwiftUI provides, then reports the height
/// produced by the layout manager at that width. `widthTracksTextView = true`
/// keeps the text container synced with frame changes; `layout()` invalidates
/// the intrinsic size after each pass so SwiftUI re-reads the new height.
///
/// No `sizeThatFits` override — that route is fragile under `.infinity`
/// proposals (e.g. initial layout passes inside a `NavigationSplitView`
/// detail column) and would require a separate measurement stack to avoid
/// polluting the render container.
struct MarkdownTextView: NSViewRepresentable {
    let attributed: NSAttributedString
    let linkColor: NSColor
    let onOpenURL: (URL) -> Void
    var inlineCodeHPadding: CGFloat = 4
    var inlineCodeVPadding: CGFloat = 0
    var inlineCodeCornerRadius: CGFloat = 3

    func makeNSView(context: Context) -> WrappedTextView {
        // Custom layout manager so inline-code chips can be drawn with
        // horizontal padding and rounded corners.
        let textStorage = NSTextStorage()
        let layoutManager = MarkdownLayoutManager()
        layoutManager.inlineCodeHorizontalPadding = inlineCodeHPadding
        layoutManager.inlineCodeVerticalPadding = inlineCodeVPadding
        layoutManager.inlineCodeCornerRadius = inlineCodeCornerRadius
        let containerSize = CGSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude)
        let container = NSTextContainer(size: containerSize)
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        let tv = WrappedTextView(frame: .zero, textContainer: container)
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.isRichText = true
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.textContainerInset = NSSize.zero
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = []
        // Layer-backed + 内容只在 setNeedsDisplay 时重画:NSScrollView live scroll
        // 期不再每帧同步 drawRect,而是 GPU composite 缓存的 layer bitmap。
        tv.wantsLayer = true
        tv.layerContentsRedrawPolicy = .onSetNeedsDisplay
        let linkAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: linkColor,
            .cursor: NSCursor.pointingHand,
        ]
        tv.linkTextAttributes = linkAttrs
        tv.onOpenURL = onOpenURL
        tv.textStorage?.setAttributedString(attributed)
        return tv
    }

    func updateNSView(_ nsView: WrappedTextView, context: Context) {
        // Short-circuit:SwiftUI 的 reconcile 每帧可能对 NSViewRepresentable 狂调
        // updateNSView(即使上层 body 不重跑)。用指针身份比较 + NSColor 等值
        // 避免做 O(字符数) 的 isEqual 和冗余 dict 重建。
        let paddingChanged = nsView.cachedInlineCodeHPadding != inlineCodeHPadding
            || nsView.cachedInlineCodeVPadding != inlineCodeVPadding
            || nsView.cachedInlineCodeCornerRadius != inlineCodeCornerRadius
        let linkColorChanged = nsView.cachedLinkColor != linkColor
        let storageChanged = nsView.cachedAttributed !== attributed
        if !paddingChanged && !linkColorChanged && !storageChanged {
            nsView.onOpenURL = onOpenURL   // 闭包地址可能每帧变,便宜赋值即可
            return
        }

        nsView.onOpenURL = onOpenURL

        if linkColorChanged {
            nsView.linkTextAttributes = [
                .foregroundColor: linkColor,
                .cursor: NSCursor.pointingHand,
            ]
            nsView.cachedLinkColor = linkColor
        }

        if paddingChanged, let lm = nsView.layoutManager as? MarkdownLayoutManager {
            lm.inlineCodeHorizontalPadding = inlineCodeHPadding
            lm.inlineCodeVerticalPadding = inlineCodeVPadding
            lm.inlineCodeCornerRadius = inlineCodeCornerRadius
            nsView.cachedInlineCodeHPadding = inlineCodeHPadding
            nsView.cachedInlineCodeVPadding = inlineCodeVPadding
            nsView.cachedInlineCodeCornerRadius = inlineCodeCornerRadius
        }

        if storageChanged {
            nsView.textStorage?.setAttributedString(attributed)
            nsView.cachedAttributed = attributed
            nsView.invalidateIntrinsicContentSize()
        }
    }
}

final class WrappedTextView: NSTextView {
    var onOpenURL: ((URL) -> Void)?

    /// 上一次真正触发重排的 bounds size。只有 size 变化时才重排 + 通知 SwiftUI。
    /// AppKit 在 NSScrollView 的 responsive scrolling / clipView bounds 变化时可能
    /// 给每个 subview 发 `layout()`——但此时我们的 frame.size 没变,没必要重干活。
    private var lastLayoutSize: NSSize = .zero

    // MARK: - updateNSView short-circuit 缓存
    //
    // SwiftUI 的 reconcile pass 会频繁调 `updateNSView`,这些字段记录上次真正
    // 写入的值,让 representable 里的 short-circuit 用指针/等值比较快速早退。
    var cachedAttributed: NSAttributedString?
    var cachedLinkColor: NSColor?
    var cachedInlineCodeHPadding: CGFloat = -1
    var cachedInlineCodeVPadding: CGFloat = -1
    var cachedInlineCodeCornerRadius: CGFloat = -1

    /// width = `noIntrinsicMetric` → SwiftUI 给多少我用多少;
    /// height = 在当前 container 尺寸下排版后的 usedRect.height。
    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let container = textContainer else {
            return super.intrinsicContentSize
        }
        lm.ensureLayout(for: container)
        let used = lm.usedRect(for: container)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(used.height))
    }

    /// 仅在 bounds.size 真变化时执行重排 + glyph 预生成 + 通知 SwiftUI 重读 intrinsic。
    /// 滚动带来的 layout() 误触发(size 没变)会在此 guard 处早退,开销归零。
    override func layout() {
        super.layout()
        let newSize = bounds.size
        guard newSize != lastLayoutSize else { return }
        lastLayoutSize = newSize

        let t0 = CFAbsoluteTimeGetCurrent()
        if let lm = layoutManager, let container = textContainer {
            lm.ensureLayout(for: container)
            _ = lm.glyphRange(for: container)
        }
        invalidateIntrinsicContentSize()
        let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        if ms > 5 {
            appLog(.debug, "WrappedTextView",
                "layout \(ms)ms size=\(Int(newSize.width))x\(Int(newSize.height))")
        }
    }

    override func clicked(onLink link: Any, at charIndex: Int) {
        let url: URL? = {
            if let u = link as? URL { return u }
            if let s = link as? String { return URL(string: s) }
            return nil
        }()
        if let url, let onOpenURL {
            onOpenURL(url)
        } else {
            super.clicked(onLink: link, at: charIndex)
        }
    }
}
