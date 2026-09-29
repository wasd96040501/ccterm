import AppKit

/// One line of work: a run's row, one of its items, a row of news or one
/// piece of it (design/transcript/01-run.md, 04-background.md).
///
/// Tile, words, the exceptions set apart from them, trailing meta, and the
/// accessory that says what a click does — a chevron that expands, or, on
/// hover, `arrow.up.right` that opens beside. An item is indented one tile
/// and a gap, and a failed item adds its first error line under it.
///
/// Hover, selection and the flash are paint: a wash behind the line, and the
/// accessory's alpha. The accessory's slot is always laid out.
@MainActor
final class WorkLineRowView: NSView, PageRowView {
    struct Model: Equatable {
        enum Level: Equatable {
            /// A run's or news's own row: 28 pt.
            case line
            /// One item under an expanded row: 24 pt, indented 24.
            case item
        }

        enum Action: Equatable {
            /// A click opens `id` beside (a double-click pins it).
            case open(String)
            /// A click expands or collapses run `id`; the chevron shows which.
            case toggle(String, expanded: Bool)
        }

        var line: WorkLine
        var level: Level
        var action: Action
        /// The call that started a background task: ↖ on hover reveals it.
        var origin: String?
        /// A failed item's first error line, in red under it.
        var error: String?
        /// Its document is the one showing beside: the selection highlight.
        var isSelected: Bool
        /// Just brought into view by *Show in Transcript* or ↖: flash once
        /// as configured, then settle to `isSelected`.
        var flashes: Bool
    }

    weak var delegate: PageRowViewDelegate?

    private static let textFont = NSFont.systemFont(ofSize: 13)
    private static let detailFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let metaFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private static let errorFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    /// One tile and its gap: an item's indent, and where an item's own words start.
    private static let indent: CGFloat = 24
    private static let gap: CGFloat = 8
    /// How far the wash reaches past the row on each side.
    private static let washOutset: CGFloat = 4
    private static let flashDuration: CFTimeInterval = 1.2

    private let tile = ToolTileView()
    private let summary = NSTextField(labelWithString: "")
    private let exceptions = NSTextField(labelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    private let error = NSTextField(labelWithString: "")
    private let accessory = NSImageView()
    private let wash = CALayer()

    private var tileLeading: NSLayoutConstraint!
    private var tileCenter: NSLayoutConstraint!
    private var exceptionsGap: NSLayoutConstraint!
    private var errorLeading: NSLayoutConstraint!

    private var model: Model?
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            paintAccessory()
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(wash)
        wash.cornerRadius = 6
        wash.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]

        for label in [summary, exceptions, meta, error] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.cell?.truncatesLastVisibleLine = true
            addSubview(label)
        }
        summary.font = Self.textFont
        exceptions.font = Self.textFont
        meta.font = Self.metaFont
        error.font = Self.errorFont
        for label in [exceptions, meta] {
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.setContentHuggingPriority(.required, for: .horizontal)
        }
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summary.setContentHuggingPriority(.defaultLow, for: .horizontal)

        tile.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tile)
        accessory.translatesAutoresizingMaskIntoConstraints = false
        accessory.imageScaling = .scaleNone
        addSubview(accessory)

        tileLeading = tile.leadingAnchor.constraint(equalTo: leadingAnchor)
        tileCenter = tile.centerYAnchor.constraint(equalTo: topAnchor, constant: 14)
        exceptionsGap = exceptions.leadingAnchor.constraint(equalTo: summary.trailingAnchor)
        errorLeading = error.leadingAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([
            tileLeading, tileCenter, exceptionsGap, errorLeading,
            summary.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: Self.gap),
            summary.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            exceptions.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            meta.leadingAnchor.constraint(greaterThanOrEqualTo: exceptions.trailingAnchor, constant: Self.gap),
            meta.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            meta.trailingAnchor.constraint(equalTo: accessory.leadingAnchor, constant: -Self.gap),
            accessory.trailingAnchor.constraint(equalTo: trailingAnchor),
            accessory.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            accessory.widthAnchor.constraint(equalToConstant: 12),
            accessory.heightAnchor.constraint(equalToConstant: 12),
            error.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            error.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            error.heightAnchor.constraint(equalToConstant: 20),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - Height

    private static func lineHeight(_ level: Model.Level) -> CGFloat {
        switch level {
        case .line: 28
        case .item: 24
        }
    }

    static func height(for model: Model, width: CGFloat) -> CGFloat {
        switch model.level {
        case .line: 28
        case .item: model.error == nil ? 24 : 44
        }
    }

    // MARK: - Model

    func configure(with model: Model) {
        let previous = self.model
        self.model = model
        let lineHeight = Self.lineHeight(model.level)

        tile.tile = model.line.tile
        tileLeading.constant = model.level == .item ? Self.indent : 0
        tileCenter.constant = lineHeight / 2
        errorLeading.constant = Self.indent + Self.indent

        summary.attributedStringValue = Self.summaryString(model.line)
        let exceptionsText = Self.truncated(
            model.line.exceptions.attributedString(font: Self.textFont, color: .secondaryLabelColor))
        exceptions.attributedStringValue = exceptionsText
        exceptions.isHidden = model.line.exceptions.isEmpty
        exceptionsGap.constant = model.line.exceptions.isEmpty ? 0 : 4
        let metaText = Self.truncated(model.line.meta.attributedString(font: Self.metaFont, color: .tertiaryLabelColor))
        meta.attributedStringValue = metaText
        meta.isHidden = model.line.meta.isEmpty

        error.stringValue = model.error ?? ""
        error.textColor = NSColor.failureText.withAlphaComponent(0.9)
        error.isHidden = model.error == nil

        paintAccessory()
        var label = model.line.text.string + model.line.exceptions.string
        if !model.line.meta.isEmpty { label += ", " + model.line.meta.string }
        setAccessibilityLabel(label)

        needsLayout = true
        needsDisplay = true
        refreshHover()
        flash(if: model.flashes && previous?.flashes != true)
        if !model.flashes { wash.removeAnimation(forKey: "flash") }
    }

    private static func truncated(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        result.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: result.length))
        return result
    }

    /// The text, then the detail in monospaced tertiary: one run of words,
    /// so a short line cuts the detail before it cuts the text.
    private static func summaryString(_ line: WorkLine) -> NSAttributedString {
        let result = NSMutableAttributedString(
            attributedString: line.text.attributedString(font: textFont, color: .secondaryLabelColor))
        if let detail = line.detail, !detail.isEmpty {
            result.append(NSAttributedString(string: " ", attributes: [.font: textFont, .kern: 2.6]))
            result.append(
                NSAttributedString(
                    string: detail, attributes: [.font: detailFont, .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        return truncated(result)
    }

    // MARK: - Accessory

    /// The slot always holds a glyph; only its alpha says whether it shows.
    private func paintAccessory() {
        guard let model else { return }
        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        let name: String
        var visible = isHovered
        if model.origin != nil {
            name = "arrow.up.left"
        } else {
            switch model.action {
            case .toggle(_, let expanded):
                name = expanded ? "chevron.down" : "chevron.right"
                visible = true
            case .open:
                name = "arrow.up.right"
            }
        }
        accessory.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        accessory.contentTintColor = .tertiaryLabelColor
        accessory.alphaValue = visible ? 1 : 0
    }

    // MARK: - Wash

    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        updateWashFrame()
    }

    private func updateWashFrame() {
        let height = Self.lineHeight(model?.level ?? .line)
        wash.frame = NSRect(
            x: -Self.washOutset, y: bounds.height - height, width: bounds.width + 2 * Self.washOutset, height: height)
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            wash.backgroundColor = baseWash().cgColor
        }
    }

    private func baseWash() -> NSColor {
        if model?.isSelected == true { return Self.selectionColor }
        return isHovered ? .quaternarySystemFill : .clear
    }

    private static let selectionColor = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor.controlAccentColor.withAlphaComponent(dark ? 0.24 : 0.13)
    }

    /// Selection colour for a beat, then it fades to what the row settles to;
    /// Reduce Motion holds it, then drops.
    private func flash(if start: Bool) {
        guard start, window != nil else { return }
        wash.removeAnimation(forKey: "flash")
        var from = Self.selectionColor.cgColor
        var to = baseWash().cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            from = Self.selectionColor.cgColor
            to = baseWash().cgColor
        }
        let animation = CAKeyframeAnimation(keyPath: "backgroundColor")
        animation.values = [from, from, to]
        animation.keyTimes = [0, 0.3, 1]
        animation.duration = Self.flashDuration
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            animation.values = [from, to]
            animation.keyTimes = [0, 1]
            animation.calculationMode = .discrete
        }
        wash.add(animation, forKey: "flash")
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }

    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { isHovered = false }
    }

    /// A recycled view is under a new row while the pointer hasn't moved.
    private func refreshHover() {
        guard let window else {
            isHovered = false
            return
        }
        isHovered = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Clicks

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        defer { super.mouseDown(with: event) }
        guard let model, let delegate else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let origin = model.origin, accessory.frame.insetBy(dx: -6, dy: -6).contains(point) {
            delegate.rowView(self, revealOrigin: origin)
        } else if let id = openedNoun(at: point) {
            delegate.rowView(self, open: id, pinned: event.clickCount == 2)
        } else {
            switch model.action {
            case .toggle(let id, _): delegate.rowView(self, toggle: id, all: event.modifierFlags.contains(.option))
            case .open(let id): delegate.rowView(self, open: id, pinned: event.clickCount == 2)
            }
        }
    }

    /// The id a named file under `point` opens, when it is a link.
    private func openedNoun(at point: NSPoint) -> String? {
        guard summary.frame.contains(point), let cell = summary.cell else { return nil }
        let local = summary.convert(point, from: self)
        let title = cell.titleRect(forBounds: summary.bounds)
        let storage = NSTextStorage(attributedString: summary.attributedStringValue)
        let container = NSTextContainer(size: NSSize(width: title.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let inText = NSPoint(x: local.x - title.minX, y: title.maxY - local.y)
        var fraction: CGFloat = 0
        let index = layoutManager.characterIndex(
            for: inText, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard index < storage.length else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        guard
            layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(
                inText)
        else { return nil }
        return storage.attribute(StyledText.opensKey, at: index, effectiveRange: nil) as? String
    }
}
