import AppKit

/// The composer's round button (design 08 *The action button*): a 28-pt circle
/// holding the accent arrow of Send — grey while there is nothing to send — or
/// the stop square, in the label colour, while Claude works or starts.
@MainActor
final class ComposerActionButton: NSButton {
    enum Kind {
        case send
        case stop
    }

    static let diameter: CGFloat = 28

    let kind: Kind

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        isBordered = false
        title = ""
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = Self.diameter / 2
        // preview-live.css `.act-btn svg`: the arrow 14 pt, the stop square 10.
        switch kind {
        case .send:
            image = ComposerGlyph.asset(.composerSend, NSSize(width: 14, height: 14))
        case .stop:
            image = ComposerGlyph.asset(.composerStop, NSSize(width: 10, height: 10))
        }
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.diameter),
            heightAnchor.constraint(equalToConstant: Self.diameter),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let fill: NSColor
            let ink: NSColor
            switch kind {
            case .send where isEnabled:
                fill = .controlAccentColor
                ink = .white
            case .send:
                fill = .composerTile
                ink = .tertiaryLabelColor
            case .stop:
                fill = .labelColor
                ink = .windowBackgroundColor
            }
            layer?.backgroundColor =
                (isHighlighted ? fill.blended(withFraction: 0.15, of: .black) ?? fill : fill).cgColor
            contentTintColor = ink
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
