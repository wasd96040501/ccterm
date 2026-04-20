import AppKit
import SwiftUI

/// Renders a prebuilt `NSAttributedString` for a single `.markdown` segment
/// using TextKit 1 + `NSTextView`. Read-only, selectable, link-aware.
///
/// `sizeThatFits` measures the layout for the proposed width so SwiftUI gives
/// the view exactly the height it needs — no scroll view, no explicit frame.
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

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: WrappedTextView,
        context: Context
    ) -> CGSize? {
        let width = proposal.width ?? 400
        guard
            let container = nsView.textContainer,
            let layout = nsView.layoutManager
        else { return nil }
        container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: width, height: ceil(used.height))
    }
}

final class WrappedTextView: NSTextView {
    var onOpenURL: ((URL) -> Void)?

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
