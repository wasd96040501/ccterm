import AppKit

/// AppKit replacement for `InputBarView2`'s `attachmentCard` + `AttachmentCard`
/// hover wrapper (migration plan §4.1, §4.7-1). One card per `Attachment`:
///
/// - **image kind** — an aspect-FILL 48×48 thumbnail clipped to a
///   `cornerRadius 6, .continuous` rounded rect with a 0.5pt `separatorColor`
///   border. Clickable → `onTapped` (routes to the owned image preview).
/// - **file kind** — an aspect-FIT 32×32 system icon + middle-truncated 12pt
///   filename on a `controlBackgroundColor.opacity(0.6)` rounded backplate
///   (cornerRadius 6) with the same 0.5pt border. No preview tap.
///
/// A top-trailing remove-X chip (`xmark.circle.fill`, palette white / black
/// 0.65, 16pt) fades in on hover via this card's OWN `NSTrackingArea` (so hover
/// never bleeds across sibling cards — matching the SwiftUI per-instance
/// `@State`, InputBarView2.swift:721,738). Click → `onRemove`.
final class AttachmentCardView: NSView {

    // MARK: - Constants (verbatim from InputBarView2.swift)

    /// 48×48 image / file card height (`thumbnailSize`).
    static let thumbnailSize: CGFloat = AttachmentStripView.thumbnailSize
    /// Card content corner radius (InputBarView2.swift:278,305).
    private static let cardCornerRadius: CGFloat = 6
    /// 0.5pt `separatorColor` border (InputBarView2.swift:281,310).
    private static let borderWidth: CGFloat = 0.5
    /// File-card icon is `thumbnailSize - 16 = 32` (InputBarView2.swift:295).
    private static let fileIconSize: CGFloat = thumbnailSize - 16
    /// File-card filename font (InputBarView2.swift:297).
    private static let filenameFontSize: CGFloat = 12
    /// `HStack(spacing: 8)` + `.padding(.horizontal, 8)` (InputBarView2.swift:291,302).
    private static let fileContentSpacing: CGFloat = 8
    private static let fileContentHorizontalPadding: CGFloat = 8
    /// Remove-X glyph point size (InputBarView2.swift:730).
    private static let removeGlyphSize: CGFloat = 16
    /// `.padding(2)` on the remove chip (InputBarView2.swift:733).
    private static let removeChipPadding: CGFloat = 2
    /// `.animation(.easeOut(duration: 0.12), value: isHovered)` (InputBarView2.swift:735).
    private static let hoverAnimationDuration: TimeInterval = 0.12

    // MARK: - Callbacks

    /// Fired when the remove-X chip is clicked.
    var onRemove: (() -> Void)?
    /// Fired when an IMAGE card's thumbnail is clicked (nil for file cards —
    /// only image kind shows a clickable thumbnail, InputBarView2.swift:269-286).
    var onTapped: (() -> Void)?

    // MARK: - State

    let attachment: Attachment
    private var trackingArea: NSTrackingArea?

    // MARK: - Subviews

    /// The 48×48 content view (image thumbnail OR file row). The remove-X
    /// floats above it at top-trailing.
    private let content: NSView
    private let removeButton = RemoveChipButton()

    // MARK: - Init

    init(attachment: Attachment) {
        self.attachment = attachment
        switch attachment.kind {
        case .image:
            content = Self.makeImageContent(attachment)
        case .file(let path):
            content = Self.makeFileContent(attachment, path: path)
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        assemble()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    nonisolated deinit {}

    private func assemble() {
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        // Remove chip floats top-trailing, faded out until hover.
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.alphaValue = 0
        removeButton.onClick = { [weak self] in self?.onRemove?() }
        addSubview(removeButton)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Self.thumbnailSize),
            // Top-trailing chip with 2pt padding (InputBarView2.swift:733).
            removeButton.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Self.removeChipPadding),
            removeButton.topAnchor.constraint(equalTo: topAnchor, constant: Self.removeChipPadding),
        ])

        setAccessibilityElement(true)

        // Resolve the dynamic cgColors against THIS view's appearance now that
        // `self` exists (the static `make*` builders seeded a construction-time
        // value before the view had an appearance — R14).
        applyCardColors()
    }

    /// Re-resolve the card's dynamic cgColors (0.5pt `separatorColor` border +,
    /// for file cards, the `controlBackgroundColor.opacity(0.6)` backplate)
    /// against the view's OWN `effectiveAppearance`. `CALayer.cgColor` doesn't
    /// auto-flip on a dark/light change AND `NSColor.separatorColor.cgColor`
    /// resolves against `NSColor.current` — which is NOT guaranteed to be this
    /// view's appearance inside `viewDidChangeEffectiveAppearance` — so wrap the
    /// reads in `performAsCurrentDrawingAppearance` (matching
    /// `InputBarView.applyDropStrokeColor`). Wrapped in a disabled
    /// `CATransaction` so the color change never crossfades (R14).
    private func applyCardColors() {
        let isFile: Bool = {
            if case .file = attachment.kind { return true } else { return false }
        }()
        var border: CGColor = NSColor.separatorColor.cgColor
        var backplate: CGColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            border = NSColor.separatorColor.cgColor
            backplate = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.layer?.borderColor = border
        if isFile { content.layer?.backgroundColor = backplate }
        CATransaction.commit()
    }

    // MARK: - Image content (aspect-FILL into 48×48)

    private static func makeImageContent(_ attachment: Attachment) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        let layer = container.layer!
        layer.cornerRadius = cardCornerRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.borderWidth = borderWidth
        layer.borderColor = NSColor.separatorColor.cgColor

        let imageView = NSImageView()
        // aspect-FILL = cover (InputBarView2.swift:276 `.aspectRatio(.fill)`).
        // NSImageView paints through its CELL using `imageScaling`, which has no
        // true cover mode — `.scaleAxesIndependently` would distort a non-square
        // thumbnail and `.scaleProportionallyUpOrDown` would letterbox it. So we
        // drive the LAYER directly: feed the thumbnail to `layer.contents` (NOT
        // `.image`, which an NSImageView would not mirror into `contents`) and
        // let `.resizeAspectFill` + `masksToBounds` crop to an exact cover.
        imageView.wantsLayer = true
        imageView.image = nil
        imageView.layer?.contents = attachment.thumbnail
        imageView.layer?.contentsGravity = .resizeAspectFill
        imageView.layer?.masksToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: thumbnailSize),
            container.heightAnchor.constraint(equalToConstant: thumbnailSize),
        ])
        // `.help(attachment.filename)` (InputBarView2.swift:285).
        container.toolTip = attachment.filename
        return container
    }

    // MARK: - File content (aspect-FIT 32×32 icon + middle-truncated name)

    private static func makeFileContent(_ attachment: Attachment, path: String) -> NSView {
        let backplate = NSView()
        backplate.wantsLayer = true
        let layer = backplate.layer!
        layer.cornerRadius = cardCornerRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.borderWidth = borderWidth
        layer.borderColor = NSColor.separatorColor.cgColor
        layer.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor

        let icon = NSImageView()
        icon.image = attachment.thumbnail
        icon.imageScaling = .scaleProportionallyUpOrDown  // aspect-FIT
        icon.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: attachment.filename)
        name.font = .systemFont(ofSize: filenameFontSize)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingMiddle  // `.truncationMode(.middle)`
        name.maximumNumberOfLines = 1
        name.cell?.usesSingleLineMode = true
        name.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [icon, name])
        row.orientation = .horizontal
        row.spacing = fileContentSpacing
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(
            top: 0, left: fileContentHorizontalPadding, bottom: 0,
            right: fileContentHorizontalPadding)
        row.translatesAutoresizingMaskIntoConstraints = false
        backplate.addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: backplate.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: backplate.trailingAnchor),
            row.topAnchor.constraint(equalTo: backplate.topAnchor),
            row.bottomAnchor.constraint(equalTo: backplate.bottomAnchor),
            backplate.heightAnchor.constraint(equalToConstant: thumbnailSize),
            icon.widthAnchor.constraint(equalToConstant: fileIconSize),
            icon.heightAnchor.constraint(equalToConstant: fileIconSize),
        ])
        // `.help(path)` (InputBarView2.swift:312).
        backplate.toolTip = path
        return backplate
    }

    // MARK: - Click (image thumbnail tap → preview)

    override func mouseDown(with event: NSEvent) {
        // Only image cards have a tap target; the remove chip is a separate
        // subview that handles its own clicks (and is hit first when hovered).
        guard onTapped != nil else { return }
        // Standard button semantics: fire only if the mouse-up lands inside.
        // The remove chip owns its own bounds, so a click there reaches it,
        // not us.
    }

    override func mouseUp(with event: NSEvent) {
        guard let onTapped else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard content.frame.contains(p) else { return }
        onTapped()
    }

    // MARK: - Hover (per-card NSTrackingArea — no sibling bleed)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private var isHovered = false
    private func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.hoverAnimationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            removeButton.animator().alphaValue = hovered ? 1 : 0
        }
    }

    // MARK: - Appearance re-resolution (R14 — cgColor freezes on flip)

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyCardColors()
    }
}

/// The top-trailing `xmark.circle.fill` remove chip. Palette-rendered
/// (white glyph / black-0.65 ring), 16pt; fixed intrinsic size from the chip
/// glyph plus the 2pt padding the card adds via its constraint.
private final class RemoveChipButton: NSControl {

    var onClick: (() -> Void)?
    private let iconView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            .applying(
                .init(paletteColors: [.white, NSColor.black.withAlphaComponent(0.65)]))
        iconView.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: String(localized: "Remove attachment"))?
            .withSymbolConfiguration(config)
        iconView.imageScaling = .scaleNone
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.trailingAnchor.constraint(equalTo: trailingAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor),
            iconView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        setAccessibilityRole(.button)
        setAccessibilityLabel(String(localized: "Remove attachment"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    nonisolated deinit {}

    override var intrinsicContentSize: NSSize {
        iconView.image?.size ?? NSSize(width: 16, height: 16)
    }

    override func mouseDown(with event: NSEvent) {
        // Swallow the press so it doesn't reach the card's image-tap path.
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }
}
