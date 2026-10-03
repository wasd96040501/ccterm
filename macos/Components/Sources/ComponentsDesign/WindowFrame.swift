import AppKit

/// The design's window drawn around real content, at the window's content
/// size: corners, hairline edge and shadows, the traffic lights, and the
/// window's own chrome — `design/settings/index.html`'s Settings window (the
/// lights over the sidebar, a toolbar row floating over the detail: back and
/// forward, then the pane's title) and `design/transcript/index.html`'s
/// Playground (a 44-high title bar: the lights, the title over its subtitle).
///
/// It is its own card on the style page: nothing around it. The content is
/// the app's real view, laid out at `contentSize`; the frame never re-lays it
/// out narrower (the page scales the frame whole, `ScaledHost`). The images
/// the chrome draws come from `WindowChromeImages`.
final class WindowFrame: NSView {
    enum Chrome {
        /// design/settings' `.window`: 15-pt corners, the content full-bleed;
        /// the lights at (19, 19), and from `detailLeading` on, over the
        /// detail, a 52-high toolbar row.
        case settings(detailLeading: CGFloat)
        /// design/transcript's `.window`: 14-pt corners, a 44-high title bar
        /// of its own colour with a hairline under it.
        case titled(title: String, subtitle: String)
    }

    /// The title bar's height in `.titled`.
    static let titleBarHeight: CGFloat = 44
    /// The toolbar row's height in `.settings`.
    static let toolbarHeight: CGFloat = 52

    /// The pane's title in the toolbar row of `.settings`.
    var title: String {
        get { toolbar?.title ?? "" }
        set { toolbar?.title = newValue }
    }

    var onBack: (() -> Void)? {
        get { toolbar?.onBack }
        set { toolbar?.onBack = newValue }
    }

    var onForward: (() -> Void)? {
        get { toolbar?.onForward }
        set { toolbar?.onForward = newValue }
    }

    func setHistory(canGoBack: Bool, canGoForward: Bool) {
        toolbar?.setHistory(canGoBack: canGoBack, canGoForward: canGoForward)
    }

    /// The frame's own size: the content's, and a title bar's more in `.titled`.
    let size: NSSize

    private var toolbar: ToolbarRow?

    /// `overlay` covers the whole window, above everything: a sheet on its
    /// scrim.
    init(content: NSView, contentSize: NSSize, chrome: Chrome, overlay: NSView? = nil) {
        let barHeight: CGFloat
        let elevated: ElevatedView
        switch chrome {
        case .settings:
            barHeight = 0
            elevated = ElevatedView(
                radius: 15, fill: .design(light: .design(hex: 0xffffff), dark: .design(hex: 0x282828)),
                shadow: .init(
                    ring: (.design(white: 0, alpha: 0.18), .design(white: 0, alpha: 0.8)),
                    innerRing: .design(white: 1, alpha: 0.12),
                    drops: [
                        (22, 60, .design(white: 0, alpha: 0.22), .design(white: 0, alpha: 0.5)),
                        (6, 16, .design(white: 0, alpha: 0.1), .design(white: 0, alpha: 0)),
                    ]))
        case .titled:
            barHeight = Self.titleBarHeight
            elevated = ElevatedView(
                radius: 14, fill: .design(light: .design(hex: 0xffffff), dark: .design(hex: 0x1e1e1e)),
                shadow: .init(
                    ring: (.design(white: 0, alpha: 0.12), .design(white: 1, alpha: 0.14)),
                    innerRing: nil,
                    drops: [(12, 40, .design(white: 0, alpha: 0.1), .design(white: 0, alpha: 0.5))]))
        }
        size = NSSize(width: contentSize.width, height: contentSize.height + barHeight)
        super.init(frame: NSRect(origin: .zero, size: size))
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(elevated)
        elevated.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width),
            heightAnchor.constraint(equalToConstant: size.height),
            elevated.topAnchor.constraint(equalTo: topAnchor),
            elevated.bottomAnchor.constraint(equalTo: bottomAnchor),
            elevated.leadingAnchor.constraint(equalTo: leadingAnchor),
            elevated.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        let surface = elevated.content
        content.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            content.topAnchor.constraint(equalTo: surface.topAnchor, constant: barHeight),
        ])

        switch chrome {
        case .settings(let detailLeading):
            let toolbar = ToolbarRow()
            self.toolbar = toolbar
            surface.addSubview(toolbar)
            NSLayoutConstraint.activate([
                toolbar.topAnchor.constraint(equalTo: surface.topAnchor),
                toolbar.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: detailLeading),
                toolbar.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
                toolbar.heightAnchor.constraint(equalToConstant: Self.toolbarHeight),
            ])
            // `.traffic`: top 19, left 19, three 14-pt lights 9 apart.
            if let lights = Self.lights(width: 3 * 14 + 2 * 9, height: 14) {
                surface.addSubview(lights)
                NSLayoutConstraint.activate([
                    lights.topAnchor.constraint(equalTo: surface.topAnchor, constant: 19),
                    lights.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 19),
                ])
            }
        case .titled(let title, let subtitle):
            let bar = TitleBar(title: title, subtitle: subtitle)
            surface.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: surface.topAnchor),
                bar.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
                bar.heightAnchor.constraint(equalToConstant: Self.titleBarHeight),
            ])
        }

        if let overlay {
            overlay.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.topAnchor.constraint(equalTo: surface.topAnchor),
                overlay.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
                overlay.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The traffic lights' image, at the design's measure; `nil` while the
    /// image is a placeholder.
    fileprivate static func lights(width: CGFloat, height: CGFloat) -> NSView? {
        guard let image = WindowChromeImages.trafficLights() else { return nil }
        let view = NSImageView(image: image)
        view.imageScaling = .scaleProportionallyUpOrDown
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: width),
            view.heightAnchor.constraint(equalToConstant: height),
        ])
        return view
    }
}

// MARK: - Title bar

/// `.titlebar` (design/transcript): the chrome colour, a hairline under it;
/// the lights 14 in, then 12 on, the title (13 semibold) over the subtitle
/// (11, secondary).
private final class TitleBar: NSView {
    init(title: String, subtitle: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = NSTextField(labelWithString: subtitle)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        let words = NSStackView(views: [name, detail])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 0
        let hairline = NSView()
        hairline.wantsLayer = true
        hairline.identifier = NSUserInterfaceItemIdentifier("hairline")
        for view in [words, hairline] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        var leading = leadingAnchor
        var gap: CGFloat = 14
        if let lights = WindowFrame.lights(width: 3 * 12 + 2 * 8, height: 12) {
            addSubview(lights)
            NSLayoutConstraint.activate([
                lights.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
                lights.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            leading = lights.trailingAnchor
            gap = 12
        }
        NSLayoutConstraint.activate([
            words.leadingAnchor.constraint(equalTo: leading, constant: gap),
            words.centerYAnchor.constraint(equalTo: centerYAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 0.5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Self.chrome.cgColor
        subviews.first { $0.identifier?.rawValue == "hairline" }?.layer?.backgroundColor =
            NSColor.separatorColor.cgColor
    }

    /// `--chrome`: the tab bar's and title bar's colour.
    private static let chrome = NSColor.design(light: .design(hex: 0xf6f6f7), dark: .design(hex: 0x262628))
}

// MARK: - Toolbar row

/// design/settings' `.toolbar`: 52 high over the detail, a fade from the
/// window's colour to nothing; 8 in, the 73 × 36 history pill — back and
/// forward 36 square either side of a hairline — then the pane's title, 13
/// on, 15 semibold.
private final class ToolbarRow: NSView {
    var title: String {
        get { titleLabel.stringValue }
        set { titleLabel.stringValue = newValue }
    }
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let pill = HistoryPill()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        pill.back.target = self
        pill.back.action = #selector(back(_:))
        pill.forward.target = self
        pill.forward.action = #selector(forward(_:))
        for view in [pill, titleLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            pill.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: pill.trailingAnchor, constant: 13),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func setHistory(canGoBack: Bool, canGoForward: Bool) {
        pill.back.isEnabled = canGoBack
        pill.forward.isEnabled = canGoForward
    }

    @objc private func back(_ sender: Any?) { onBack?() }
    @objc private func forward(_ sender: Any?) { onForward?() }

    /// The pill and title float over the pane: only what they cover takes
    /// the click; the fade is a drawing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func draw(_ dirtyRect: NSRect) {
        let win = NSColor.design(light: .design(hex: 0xffffff), dark: .design(hex: 0x282828))
        var solid = NSColor.clear
        var clear = NSColor.clear
        effectiveAppearance.performAsCurrentDrawingAppearance {
            solid = NSColor(cgColor: win.cgColor) ?? win
            clear = solid.withAlphaComponent(0)
        }
        // From the top (55 % solid) to nothing at the bottom, in either flip.
        let gradient = NSGradient(colors: [solid, solid, clear], atLocations: [0, 0.55, 1], colorSpace: .sRGB)
        gradient?.draw(in: bounds, angle: isFlipped ? 90 : -90)
    }
}

/// `.history`: 73 × 36, fully rounded, a translucent fill, a hairline edge.
private final class HistoryPill: NSView {
    let back = ChevronButton(image: WindowChromeImages.back(), label: "Back")
    let forward = ChevronButton(image: WindowChromeImages.forward(), label: "Forward")
    private let divider = NSView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        divider.wantsLayer = true
        for view in [back, divider, forward] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 73),
            heightAnchor.constraint(equalToConstant: 36),
            back.leadingAnchor.constraint(equalTo: leadingAnchor),
            back.topAnchor.constraint(equalTo: topAnchor),
            back.widthAnchor.constraint(equalToConstant: 36),
            back.heightAnchor.constraint(equalToConstant: 36),
            divider.leadingAnchor.constraint(equalTo: back.trailingAnchor),
            divider.centerYAnchor.constraint(equalTo: centerYAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 18),
            forward.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            forward.topAnchor.constraint(equalTo: topAnchor),
            forward.widthAnchor.constraint(equalToConstant: 36),
            forward.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        // `--glass` and `--glass-edge`.
        let edge = isDark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.1)
        layer?.backgroundColor =
            (isDark ? NSColor(srgbRed: 60 / 255, green: 60 / 255, blue: 62 / 255, alpha: 0.72) : NSColor(white: 1, alpha: 0.78))
            .cgColor
        layer?.borderColor = edge.cgColor
        layer?.borderWidth = 0.5
        divider.layer?.backgroundColor = edge.cgColor
        layer?.shadowColor = NSColor(white: 0, alpha: 0.06).cgColor
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        layer?.shadowRadius = 1.5
        layer?.shadowOpacity = 1
    }
}

/// A chevron button, 36 square; the image is `WindowChromeImages`'.
private final class ChevronButton: NSButton {
    init(image: NSImage?, label: String) {
        super.init(frame: .zero)
        self.image = image
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        setAccessibilityLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isEnabled: Bool {
        didSet { contentTintColor = isEnabled ? .labelColor : .tertiaryLabelColor }
    }
}
