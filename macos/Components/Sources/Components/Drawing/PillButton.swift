import AppKit

/// The design's `.btn`, the one button rows and documents answer with: a
/// 22-pt pill, a 13-pt title, a quaternary fill and a hairline ring — or,
/// primary, the accent colour under white ink. `keys` follows the title dimmed
/// and a size smaller, as the design's `kbd`; it only shows the key, the
/// owner still sets `keyEquivalent`.
@MainActor
public final class PillButton: NSButton {
    private static let height: CGFloat = 22
    private static let padding: CGFloat = 14
    /// The design's `kbd { margin-left: 6px }`.
    private static let keysGap: CGFloat = 6

    private let isPrimary: Bool

    public init(title: String, keys: String? = nil, isPrimary: Bool = false) {
        self.isPrimary = isPrimary
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
        layer?.borderWidth = isPrimary ? 0 : 0.5
        attributedTitle = Self.label(title, keys: keys, ink: isPrimary ? .white : .labelColor)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private static func label(_ title: String, keys: String?, ink: NSColor) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: title, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: ink])
        guard let keys else { return text }
        text.addAttribute(.kern, value: keysGap, range: NSRange(location: text.length - 1, length: 1))
        // Dimmed in the appearance it is drawn in: `withAlphaComponent` on a
        // dynamic colour fixes it in the one current when it is made.
        let dimmed = NSColor(name: nil) { appearance in
            var resolved = ink
            appearance.performAsCurrentDrawingAppearance { resolved = NSColor(cgColor: ink.cgColor) ?? ink }
            return resolved.withAlphaComponent(0.7)
        }
        text.append(
            NSAttributedString(
                string: keys, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: dimmed]))
        return text
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(attributedTitle.size().width) + 2 * Self.padding, height: Self.height)
    }

    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let fill: NSColor = isPrimary ? .controlAccentColor : .quaternarySystemFill
            let shade: NSColor = isPrimary ? .black : .labelColor
            layer?.backgroundColor =
                (isHighlighted ? fill.blended(withFraction: 0.15, of: shade) ?? fill : fill).cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    public override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    /// Disabled, the whole pill fades, as a disabled `.btn` does.
    public override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.5 }
    }
}
