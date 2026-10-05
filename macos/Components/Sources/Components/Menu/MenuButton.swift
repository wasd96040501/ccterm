import AppKit

/// The button a `MenuPopover` opens from (design 08 *Menus are popovers*):
/// AppKit's accessory-bar button, its bezel shown under the pointer, darker
/// while pressed and on while its popover is open. It acts on release, as any
/// button does. The bezel is as tall as its control size, which holds a
/// chip's words; a larger title (the New view's folder) takes the
/// variable-height push bezel instead.
///
/// Only the popover turns it on and off: a press sends the action and leaves
/// the state as it is (`Cell.nextState`), so the button can't show a menu
/// that isn't open.
///
/// The cell lays out what it shows: the glyph as its image before the words,
/// then the tertiary detail, a trailing glyph and the chevron.
@MainActor
package final class MenuButton: NSButton {
    /// A press moves the button to the state it is in.
    private final class Cell: NSButtonCell {
        override var nextState: Int { state.rawValue }
    }

    override package class var cellClass: AnyClass? {
        get { Cell.self }
        set {}
    }

    package init() {
        super.init(frame: .zero)
        title = ""
        bezelStyle = .accessoryBar
        setButtonType(.pushOnPushOff)
        showsBorderOnlyWhileMouseInside = true
        imagePosition = .imageLeading
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Shows `title` in `font` and `ink` after `glyph` (a template image, in
    /// `ink` too), then `detail` and `trailing` in tertiary ink, then the
    /// chevron in `chevronInk` (`ink` by default) when `hasChevron`.
    package func show(
        _ title: String, font: NSFont, ink: NSColor, glyph: NSImage? = nil, detail: String? = nil,
        trailing: NSImage? = nil, chevronInk: NSColor? = nil, hasChevron: Bool = true
    ) {
        let words = NSMutableAttributedString(string: title, attributes: [.font: font, .foregroundColor: ink])
        func append(_ string: NSAttributedString) {
            if words.length > 0 { words.append(NSAttributedString(string: " ", attributes: [.font: font])) }
            words.append(string)
        }
        if let detail {
            append(
                NSAttributedString(
                    string: detail, attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        if let trailing { append(Self.inline(trailing, font: font, ink: .tertiaryLabelColor)) }
        if hasChevron, let chevron = Self.chevron { append(Self.inline(chevron, font: font, ink: chevronInk ?? ink)) }
        // The cell sets its words in the middle of the bezel by its own font.
        self.font = font
        attributedTitle = words
        image = glyph
        contentTintColor = ink
        setAccessibilityLabel(title)
    }

    /// The chevron: an SF Symbol, so it sits on the words' baseline as a
    /// character does.
    private static let chevron = NSImage.symbol("chevron.down", pointSize: 8, weight: .semibold)

    /// `image` as a character of the words, in `ink`.
    private static func inline(_ image: NSImage, font: NSFont, ink: NSColor) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = image
        let string = NSMutableAttributedString(attachment: attachment)
        string.addAttributes([.font: font, .foregroundColor: ink], range: NSRange(location: 0, length: string.length))
        return string
    }
}
