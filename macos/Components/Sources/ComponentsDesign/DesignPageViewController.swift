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
        /// The card's content height for a view with none of its own (a scroll
        /// view); `nil`: the view's fitting height.
        var height: CGFloat? = nil
    }

    private let sections: [Section]
    private lazy var appearanceSwitch = NSSegmentedControl(
        labels: ["Auto", "Light", "Dark"], trackingMode: .selectOne, target: self,
        action: #selector(chooseAppearance(_:)))

    init(sections: [Section]) {
        self.sections = sections
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
        add(header(), to: column, fullWidth: true, after: 28)
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
            add(CardView(content: specimen.view, height: specimen.height), to: column, fullWidth: true, after: 32)
        }
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
/// and below what it holds.
private final class CardView: NSView {
    init(content: NSView, height: CGFloat?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        if let height { content.heightAnchor.constraint(equalToConstant: height).isActive = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 0.5
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
