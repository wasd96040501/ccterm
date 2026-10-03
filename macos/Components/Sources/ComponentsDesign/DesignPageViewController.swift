import AppKit

/// The style page, laid out as the design sheet (`design/transcript/index.html`,
/// `.sheet`): one column, 1160 wide at most, centred, at least 16 from the
/// window's edges; the header (title, lede, the appearance switch), then each
/// section — its heading, its note, and its specimens, each a heading over a
/// card as wide as the column. The page follows the window's width; each
/// specimen keeps the size of the host it shows (`macos/Components/CLAUDE.md`,
/// *The style page*).
final class DesignPageViewController: NSViewController {
    struct Section {
        var title: String
        /// What the section shows, under its heading.
        var note: String
        var specimens: [Specimen]
    }

    struct Specimen {
        /// What state it shows, over its card.
        var title: String
        var view: NSView
        /// The host's width, from `Host`; the card centres the view at it and
        /// scales it down whole when the column is narrower. `nil`: the
        /// design's fluid parts, as wide as the card.
        var width: CGFloat? = nil
        /// The host's height; `nil`: the view's own.
        var height: CGFloat? = nil
        /// The view is a `WindowFrame`: its own card, nothing around it.
        var isWindow = false
    }

    private let sections: [Section]
    private let showsHeader: Bool
    private lazy var appearanceSwitch = NSSegmentedControl(
        labels: ["Auto", "Light", "Dark"], trackingMode: .selectOne, target: self,
        action: #selector(chooseAppearance(_:)))

    /// `showsHeader` false: the sections alone, as a render of one section shows it.
    init(sections: [Section], showsHeader: Bool = true) {
        self.sections = sections
        self.showsHeader = showsHeader
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.backgroundColor = .designPage
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        column.setHuggingPriority(.defaultLow, for: .horizontal)
        document.addSubview(column)
        if showsHeader { add(header(), to: column, fullWidth: true, after: 28) }
        for section in sections { add(section, to: column) }

        // The column wants the window's width less 16 a side, and gives way to
        // its 1160 limit; centred in whatever is left. It wants it less than
        // the window wants to keep its size, or a wide window would be pulled
        // in to the column's.
        let fill = column.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -32)
        fill.priority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 1)
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            column.topAnchor.constraint(equalTo: document.topAnchor, constant: 48),
            column.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -120),
            column.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: 1160),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: 16),
            fill,
        ])
        view = scroll
    }

    // MARK: - The sheet's parts

    /// `h1`, the lede under it, and the appearance switch at the trailing edge.
    private func header() -> NSView {
        let title = Self.label("CCTerm components", size: 28, weight: .bold)
        let lede = WrappingLabel(
            wrappingLabelWithString:
                "Every view the app draws with, from Components — live, at the window's width. Each section builds a "
                + "part of the design sheet with the component the app uses.")
        lede.font = .systemFont(ofSize: 13)
        lede.textColor = .secondaryLabelColor
        let words = NSStackView(views: [title, lede])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 6
        lede.widthAnchor.constraint(lessThanOrEqualToConstant: 720).isActive = true
        appearanceSwitch.selectedSegment = 0
        // The words from the leading edge, the switch at the trailing one, 24
        // apart at least; the header as tall as the taller.
        let header = NSView()
        for view in [words, appearanceSwitch] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        NSLayoutConstraint.activate([
            words.topAnchor.constraint(equalTo: header.topAnchor),
            words.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            words.trailingAnchor.constraint(lessThanOrEqualTo: appearanceSwitch.leadingAnchor, constant: -24),
            words.bottomAnchor.constraint(lessThanOrEqualTo: header.bottomAnchor),
            appearanceSwitch.topAnchor.constraint(equalTo: header.topAnchor),
            appearanceSwitch.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            appearanceSwitch.bottomAnchor.constraint(lessThanOrEqualTo: header.bottomAnchor),
        ])
        // Snug under the taller of the two.
        let snug = header.heightAnchor.constraint(equalToConstant: 0)
        snug.priority = .fittingSizeCompression
        snug.isActive = true
        return header
    }

    /// `h2` 72 under what came before, the note 6 under it, then each
    /// specimen: `h3` 32 above and 10 over its card.
    private func add(_ section: Section, to column: NSStackView) {
        if let last = column.arrangedSubviews.last { column.setCustomSpacing(72, after: last) }
        let heading = Self.label(section.title, size: 20, weight: .semibold)
        add(heading, to: column, fullWidth: false, after: 4)
        let note = WrappingLabel(wrappingLabelWithString: section.note)
        note.font = .systemFont(ofSize: 13)
        note.textColor = .secondaryLabelColor
        add(note, to: column, fullWidth: false, after: 32)
        note.widthAnchor.constraint(lessThanOrEqualToConstant: 760).isActive = true
        note.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor).isActive = true
        for specimen in section.specimens {
            let title = Self.label(specimen.title, size: 13, weight: .semibold)
            title.textColor = .secondaryLabelColor
            add(title, to: column, fullWidth: false, after: 10)
            // A window's shadow reaches 50 below it.
            add(
                card(for: specimen), to: column, fullWidth: true,
                after: specimen.isWindow ? 64 : 32)
        }
    }

    /// The specimen's card: a plain one around its host, centred; none around a
    /// window, which is its own.
    private func card(for specimen: Specimen) -> NSView {
        guard let width = specimen.width else {
            let height = specimen.height
            return CardView(content: specimen.view, height: height, inset: 0, isWindow: false)
        }
        let host = ScaledHost(content: specimen.view, width: width, height: specimen.height)
        return CardView(content: host, height: nil, inset: 12, isWindow: specimen.isWindow)
    }

    private func add(_ view: NSView, to column: NSStackView, fullWidth: Bool, after spacing: CGFloat) {
        column.addArrangedSubview(view)
        column.setCustomSpacing(spacing, after: view)
        if fullWidth { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
    }

    private static func label(_ text: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        return label
    }

    /// The sheet's Auto / Light / Dark.
    @objc private func chooseAppearance(_ sender: NSSegmentedControl) {
        view.window?.appearance =
            [nil, NSAppearance(named: .aqua), NSAppearance(named: .darkAqua)][
                sender.selectedSegment]
    }
}

/// `.specimens`: the window's colour, 12-pt corners, a hairline edge, 12 above
/// and below what it holds. Content with a width of its own is centred, at
/// least `inset` from the sides; a window is the card itself, drawn without
/// one.
private final class CardView: NSView {
    private let isWindow: Bool

    init(content: NSView, height: CGFloat?, inset: CGFloat, isWindow: Bool) {
        self.isWindow = isWindow
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        let padding: CGFloat = isWindow ? 0 : 12
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
        ])
        if inset == 0 {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: leadingAnchor),
                content.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        } else {
            let fill = content.widthAnchor.constraint(equalTo: widthAnchor, constant: -2 * (isWindow ? 0 : inset))
            fill.priority = NSLayoutConstraint.Priority(740)
            NSLayoutConstraint.activate([
                content.centerXAnchor.constraint(equalTo: centerXAnchor),
                content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: isWindow ? 0 : inset),
                fill,
            ])
        }
        if let height { content.heightAnchor.constraint(equalToConstant: height).isActive = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = isWindow ? nil : NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = isWindow ? nil : NSColor.separatorColor.cgColor
        layer?.borderWidth = isWindow ? 0 : 0.5
    }
}

/// A label that wraps at whatever width the layout gives it: its height is
/// asked for at the width it was last laid out at.
private final class WrappingLabel: NSTextField {
    override func layout() {
        super.layout()
        guard preferredMaxLayoutWidth != bounds.width else { return }
        preferredMaxLayoutWidth = bounds.width
        invalidateIntrinsicContentSize()
    }
}

extension NSColor {
    /// The sheet's `--page`: under the cards.
    fileprivate static let designPage = NSColor(name: "designPage") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x0d / 255, green: 0x0d / 255, blue: 0x0f / 255, alpha: 1)
            : NSColor(srgbRed: 0xf2 / 255, green: 0xf2 / 255, blue: 0xf4 / 255, alpha: 1)
    }
}

/// Top-down, as a page reads.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
