import AppKit

/// The toolbar's search field, plus one thing: the find's `x/y`, floating over
/// the field's trailing end.
///
/// Everything else is the stock `NSSearchField` that `NSSearchToolbarItem` would
/// have made — the bezel, the magnifier, the cancel button, the expand and
/// collapse. It is a subclass only because the count has to live inside the
/// field's own view to sit over its text.
///
/// **Over the text, not beside it.** The count takes no width from what the
/// reader is typing: a query long enough to run under it keeps going, and is
/// blurred there — `.headerView` is the material AppKit uses for exactly that,
/// chrome sitting on content that passes underneath — rather than drawn through
/// the digits or cut short to make room for them.
@MainActor
final class FindSearchField: NSSearchField {

    private let countBadge = NSVisualEffectView()
    private let countLabel = NSTextField(labelWithString: "")

    /// Clear of the cancel button, which is the one thing at that end a reader
    /// has to be able to reach.
    private static let cancelButtonGap: CGFloat = 2

    init() {
        super.init(frame: .zero)

        countLabel.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right

        countBadge.material = .headerView
        countBadge.blendingMode = .withinWindow
        countBadge.state = .active
        countBadge.wantsLayer = true
        countBadge.layer?.cornerRadius = 4
        countBadge.layer?.masksToBounds = true
        countBadge.isHidden = true

        countBadge.addSubview(countLabel)
        addSubview(countBadge)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("code-only")
    }

    /// Shows `text` over the field's trailing end, or takes it away for `nil`.
    func setCount(_ text: String?) {
        countLabel.stringValue = text ?? ""
        countBadge.isHidden = text == nil
        needsLayout = true
    }

    /// Frames rather than constraints, for the one reason that decides it: the
    /// badge is placed against `cancelButtonBounds`, a rectangle the field works
    /// out for itself and exposes only as a value — there is no anchor to pin to.
    override func layout() {
        super.layout()
        let label = countLabel.fittingSize
        let size = NSSize(width: label.width + 8, height: label.height + 2)
        countBadge.frame = NSRect(
            x: cancelButtonBounds.minX - Self.cancelButtonGap - size.width,
            y: (bounds.height - size.height) / 2,
            width: size.width, height: size.height)
        countLabel.frame = NSRect(origin: NSPoint(x: 4, y: 1), size: label)
    }

    /// Keeps the badge frontmost.
    ///
    /// Editing installs the field editor *inside* this view, after the badge — so
    /// without this the text being typed would be drawn over the count it is
    /// meant to pass under. Subview order is z-order, and this is where AppKit
    /// says a subview arrived.
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        guard subview !== countBadge else { return }
        addSubview(countBadge, positioned: .above, relativeTo: nil)
    }
}
