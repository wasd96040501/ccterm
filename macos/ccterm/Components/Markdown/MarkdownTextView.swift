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

    func makeNSView(context: Context) -> WrappedTextView {
        let tv = WrappedTextView(frame: .zero)
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
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = []
        tv.linkTextAttributes = [
            .foregroundColor: linkColor,
            .cursor: NSCursor.pointingHand,
        ]
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
