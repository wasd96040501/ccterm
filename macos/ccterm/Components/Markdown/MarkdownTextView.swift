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
        nsView.onOpenURL = onOpenURL
        nsView.linkTextAttributes = [
            .foregroundColor: linkColor,
            .cursor: NSCursor.pointingHand,
        ]
        if let lm = nsView.layoutManager as? MarkdownLayoutManager {
            lm.inlineCodeHorizontalPadding = inlineCodeHPadding
            lm.inlineCodeVerticalPadding = inlineCodeVPadding
            lm.inlineCodeCornerRadius = inlineCodeCornerRadius
        }
        if nsView.textStorage?.isEqual(to: attributed) == false {
            nsView.textStorage?.setAttributedString(attributed)
            nsView.invalidateIntrinsicContentSize()
        }
    }
}

final class WrappedTextView: NSTextView {
    var onOpenURL: ((URL) -> Void)?

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

    /// frame width 变化 → `widthTracksTextView = true` 让 container 同步 →
    /// layoutManager 重排版 → 通知 SwiftUI 下一帧读新的 intrinsic height。
    override func layout() {
        super.layout()
        invalidateIntrinsicContentSize()
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
