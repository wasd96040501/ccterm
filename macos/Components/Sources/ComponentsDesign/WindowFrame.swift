import AppKit
import Components

/// The design's window drawn around real content, at the window's content
/// size: corners, hairline edge and shadows, the traffic lights, and the
/// window's own chrome — `design/settings/index.html`'s Settings window (the
/// lights over the sidebar, a toolbar row floating over the detail: back and
/// forward, then the pane's title) and `design/transcript/index.html`'s
/// Playground (a 44-high title bar: the lights, the title over its subtitle).
///
/// It is its own card on the style page: nothing around it. The content is
/// the app's real view, laid out at `contentSize`, never another (the page is
/// never narrower than its widest host). The images
/// the chrome draws are the design's (`NSImage.windowChrome…`, `.settingsBack`).
final class WindowFrame: NSView {
    enum Chrome {
        /// design/settings' `.window`: 15-pt corners, the content full-bleed;
        /// the lights at (19, 19), and from `detailLeading` on, over the
        /// detail, a 52-high toolbar row.
        case settings(detailLeading: CGFloat)
        /// design/transcript's `.window`: 14-pt corners, a 44-high title bar
        /// of its own colour with a hairline under it, the project's title in
        /// it (`MainWindowTitleView`): its name over its branch, if any.
        case titled(title: String?, subtitle: String?)
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
            // The real window's colour, as `.titled`'s: the design draws its
            // Settings window #fff and #282828.
            elevated = ElevatedView(
                radius: 15, fill: .windowBackgroundColor,
                shadow: .init(
                    ring: (.design(white: 0, alpha: 0.18), .design(white: 0, alpha: 0.8)),
                    innerRing: .design(white: 1, alpha: 0.12),
                    drops: [
                        (22, 60, .design(white: 0, alpha: 0.22), .design(white: 0, alpha: 0.5)),
                        (6, 16, .design(white: 0, alpha: 0.1), .design(white: 0, alpha: 0)),
                    ]))
        case .titled:
            barHeight = Self.titleBarHeight
            // Behind the content is the real window's colour, the system's,
            // which the dock under a session's composer fades to; the design
            // draws its window #fff and #1e1e1e.
            elevated = ElevatedView(
                radius: 14, fill: .windowBackgroundColor,
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
            let lights = Self.lights(
                [.windowChromeClose, .windowChromeMinimize, .windowChromeZoom], size: 14, gap: 9, tint: nil)
            surface.addSubview(lights)
            NSLayoutConstraint.activate([
                lights.topAnchor.constraint(equalTo: surface.topAnchor, constant: 19),
                lights.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 19),
            ])
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

    /// Three lights in a row: `size` square, `gap` apart; a template image is
    /// tinted with `tint`.
    fileprivate static func lights(_ images: [NSImage], size: CGFloat, gap: CGFloat, tint: NSColor?) -> NSView {
        let views = images.map { image -> NSImageView in
            let view = NSImageView(image: image)
            view.imageScaling = .scaleProportionallyUpOrDown
            view.contentTintColor = tint
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.widthAnchor.constraint(equalToConstant: size),
                view.heightAnchor.constraint(equalToConstant: size),
            ])
            return view
        }
        let row = NSStackView(views: views)
        row.spacing = gap
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }
}

// MARK: - Title bar

/// `.titlebar` (design/transcript): the chrome colour, a hairline under it;
/// the lights 14 in, then 12 on, the title over the subtitle — the app's own
/// `MainWindowTitleView`, as its toolbar shows it (the folder's icon, the
/// name over the branch).
private final class TitleBar: NSView {
    init(title: String?, subtitle: String?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        let words = MainWindowTitleView()
        // The branch first: set while the view is hidden it lands without its
        // fade, as a window opening on a project shows it.
        words.subtitle = subtitle
        words.title = title
        // Its fitting width, as a toolbar item takes it: no wider than its words.
        let snug = words.widthAnchor.constraint(equalToConstant: 0)
        snug.priority = .fittingSizeCompression
        snug.isActive = true
        let hairline = NSView()
        hairline.wantsLayer = true
        hairline.identifier = NSUserInterfaceItemIdentifier("hairline")
        for view in [words, hairline] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // `.lights`: three 12-pt dots 8 apart at 60 % of the tertiary label.
        let lights = WindowFrame.lights(
            [.windowChromeLight, .windowChromeLight, .windowChromeLight], size: 12, gap: 8,
            tint: NSColor.tertiaryLabelColor.withAlphaComponent(0.6))
        addSubview(lights)
        NSLayoutConstraint.activate([
            lights.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            lights.centerYAnchor.constraint(equalTo: centerYAnchor),
            words.leadingAnchor.constraint(equalTo: lights.trailingAnchor, constant: 12),
            words.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
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
    let back = ChevronButton(image: HistoryPill.chevron("chevron.left", "Back"), label: "Back")
    let forward = ChevronButton(image: HistoryPill.chevron("chevron.right", "Forward"), label: "Forward")
    private let divider = NSView()

    /// The toolbar's chevron: the system's symbol, as the real window's.
    private static func chevron(_ name: String, _ label: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)) ?? NSImage()
    }

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
            (isDark
            ? NSColor(srgbRed: 60 / 255, green: 60 / 255, blue: 62 / 255, alpha: 0.72) : NSColor(white: 1, alpha: 0.78))
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

/// A chevron button, 36 square.
private final class ChevronButton: NSButton {
    init(image: NSImage, label: String) {
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
