import AppKit
import DisplayModels

/// One line of work: a run's row, one of its items, a row of news or one
/// piece of it (design/transcript/01-run.md, 04-background.md).
///
/// Tile, words, the exceptions set apart from them, trailing meta, and the
/// accessory that says what a click does — a chevron that expands, or, on
/// hover, `arrow.up.right` that opens beside. An item is indented one tile
/// and a gap. A failed item is its red tile: why it failed is its document's.
///
/// Hover, selection and the flash are paint: a wash behind the line, and the
/// accessory's alpha. The accessory's slot is always laid out.
///
/// The row is as tall as its wash, at either level, so the wash and the
/// click reach the same box. The words sit `air` in from its top and bottom,
/// and that much of the transcript's gap is already in the box
/// (`PageRow.spacingAbove(after:)`).
///
/// Laid out by hand and its words drawn, not four text fields under
/// constraints: a screen of work lines is dozens of rows, and each one
/// mounted as the transcript scrolls paid for its fields' constraints, key
/// view loop and layers — most of what a scroll step cost. The geometry is
/// the fields' own (words where the field's alignment rect was, centred on
/// the tile), so the line reads as it did; `PageRowViewContractTests`' clause
/// on cut text doesn't reach drawn words, so the snapshots at 320 and 520 are
/// what show them.
@MainActor
public final class WorkLineRowView: NSView, PageRowView {
    public struct Model: Equatable {
        public enum Level: Equatable {
            /// A run's or news's own row.
            case line
            /// One item under an expanded row, indented 24.
            case item
        }

        public enum Action: Equatable {
            /// A click opens `id` beside (a double-click pins it).
            case open(String)
            /// A click expands or collapses run `id`; the chevron shows which.
            case toggle(String, expanded: Bool)
            /// Nothing opens: a line that says all there is to say (an advisor
            /// whose advice is encrypted). No accessory, and a click does nothing.
            case none
        }

        public var line: WorkLine
        public var level: Level
        public var action: Action
        /// The call that started a background task: ↖ on hover reveals it.
        public var origin: String?
        /// Its document is the one showing beside: the selection highlight.
        public var isSelected: Bool
        /// Just brought into view by *Show in Transcript* or ↖: flash once
        /// as configured, then settle to `isSelected`.
        public var flashes: Bool

        public init(line: WorkLine, level: Level, action: Action, origin: String?, isSelected: Bool, flashes: Bool) {
            self.line = line
            self.level = level
            self.action = action
            self.origin = origin
            self.isSelected = isSelected
            self.flashes = flashes
        }
    }

    public weak var delegate: PageRowViewDelegate?

    private static let textFont = NSFont.systemFont(ofSize: 13)
    private static let detailFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let metaFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    /// One tile and its gap: an item's indent, and where an item's own words start.
    private static let indent: CGFloat = 24
    private static let gap: CGFloat = 8
    /// How far the wash reaches past the row on each side.
    private static let washOutset: CGFloat = 4
    private static let flashDuration: CFTimeInterval = 1.2

    private static let accessorySide: CGFloat = 12

    /// The row's height, which is the wash's: a run's line and its items alike.
    static let rowHeight: CGFloat = 28
    /// Between the wash's edge and the words' line, above and below them.
    public static let air: CGFloat = 6

    private let tile = TileView()
    private let wordsView = WordsView()
    private let accessory = NSImageView()
    private let wash = CALayer()

    /// This line's words, set once per configure and placed by `layout()`.
    private var summaryText = NSAttributedString()
    private var exceptionsText = NSAttributedString()
    private var metaText = NSAttributedString()

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

        accessory.imageScaling = .scaleNone
        for view in [wordsView, tile, accessory] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    public convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    public override var isFlipped: Bool { true }

    // MARK: - Height

    public static func height(for model: Model, width: CGFloat) -> CGFloat {
        rowHeight
    }

    // MARK: - Model

    public func configure(with model: Model) {
        let previous = self.model
        self.model = model

        tile.tile = model.line.tile
        summaryText = Self.summaryString(model.line)
        exceptionsText = Self.truncated(
            model.line.exceptions.attributedString(font: Self.textFont, color: .secondaryLabelColor))
        metaText = Self.truncated(model.line.meta.attributedString(font: Self.metaFont, color: .tertiaryLabelColor))

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

    /// The text, then the detail in tertiary — monospaced for code, the text's
    /// face for words (`.callsub`), 6 pt after it: one run of words, so a short
    /// line cuts the detail before it cuts the text.
    private static func summaryString(_ line: WorkLine) -> NSAttributedString {
        let result = NSMutableAttributedString(
            attributedString: line.text.attributedString(font: textFont, color: .secondaryLabelColor))
        if let detail = line.detail, !detail.isEmpty {
            result.append(NSAttributedString(string: " ", attributes: [.font: textFont, .kern: 2.6]))
            result.append(
                NSAttributedString(
                    string: detail,
                    attributes: [
                        .font: line.detailIsWords ? textFont : detailFont, .foregroundColor: NSColor.tertiaryLabelColor,
                    ]))
        }
        return truncated(result)
    }

    // MARK: - Accessory

    /// The slot always holds a glyph; only its alpha says whether it shows.
    private func paintAccessory() {
        guard let model else { return }
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
            case .none:
                name = "arrow.up.right"
                visible = false
            }
        }
        accessory.image = .symbol(name, pointSize: 10, weight: .semibold)
        accessory.contentTintColor = .tertiaryLabelColor
        accessory.alphaValue = visible ? 1 : 0
    }

    // MARK: - Layout

    /// A field's height for `font`, which the words are centred in.
    private static func fieldHeight(_ font: NSFont) -> CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: font))
    }

    private static let textHeight = fieldHeight(textFont)
    private static let metaHeight = fieldHeight(metaFont)

    /// How wide `text` is drawn.
    private static func fieldWidth(_ text: NSAttributedString) -> CGFloat {
        text.length == 0 ? 0 : ceil(text.size().width)
    }

    /// The tile and accessory centred on the line, meta against the
    /// accessory, the words after the tile with the exceptions straight after
    /// them — and the words give way first when the line is short.
    public override func layout() {
        super.layout()
        updateWashFrame()
        guard let model else { return }
        let center = Self.rowHeight / 2
        let side = tile.intrinsicContentSize.width
        tile.frame = NSRect(x: model.level == .item ? Self.indent : 0, y: center - side / 2, width: side, height: side)
        accessory.frame = NSRect(
            x: bounds.width - Self.accessorySide, y: center - Self.accessorySide / 2, width: Self.accessorySide,
            height: Self.accessorySide)

        let metaWidth = Self.fieldWidth(metaText)
        let metaX = accessory.frame.minX - Self.gap - metaWidth
        let textX = tile.frame.maxX + Self.gap
        let exceptionsWidth = Self.fieldWidth(exceptionsText)
        let exceptionsGap: CGFloat = exceptionsWidth == 0 ? 0 : 4
        let summaryWidth = max(
            0, min(Self.fieldWidth(summaryText), metaX - Self.gap - exceptionsWidth - exceptionsGap - textX))

        func field(_ x: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
            NSRect(x: x, y: center - height / 2, width: width, height: height)
        }
        wordsView.summary = field(textX, summaryWidth, Self.textHeight)
        wordsView.exceptions = field(textX + summaryWidth + exceptionsGap, exceptionsWidth, Self.textHeight)
        wordsView.meta = field(metaX, metaWidth, Self.metaHeight)
        wordsView.texts = (summaryText, exceptionsText, metaText)
        wordsView.frame = bounds
        wordsView.needsDisplay = true
    }

    /// The line's words, drawn where `layout()` put them. A view of its own
    /// rather than the row's drawing: the wash is a layer over the row's own
    /// contents, and the words go on top of it.
    private final class WordsView: NSView {
        var texts = (NSAttributedString(), NSAttributedString(), NSAttributedString())
        var summary = NSRect.zero
        var exceptions = NSRect.zero
        var meta = NSRect.zero

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            for (text, rect) in [(texts.0, summary), (texts.1, exceptions), (texts.2, meta)]
            where text.length > 0 && rect.width > 0 {
                text.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }
    }

    // MARK: - Wash

    public override var wantsUpdateLayer: Bool { true }

    private func updateWashFrame() {
        wash.frame = NSRect(
            x: -Self.washOutset, y: 0, width: bounds.width + 2 * Self.washOutset, height: Self.rowHeight)
    }

    public override func updateLayer() {
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

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        refreshHover()
    }

    public override func mouseEntered(with event: NSEvent) { isHovered = true }

    public override func mouseExited(with event: NSEvent) { isHovered = false }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { isHovered = false }
    }

    /// Entered and exited come only when the pointer moves. A line that slid
    /// under a still pointer, or out from under it, learns so when AppKit
    /// updates its tracking areas for its new place; a recycled view, when it
    /// is configured for its new row.
    private func refreshHover() {
        guard let window, window.isKeyWindow else {
            isHovered = false
            return
        }
        isHovered = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Clicks

    public override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    public override func mouseDown(with event: NSEvent) {
        guard let model, let delegate else { return super.mouseDown(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        var opened: String?
        if let origin = model.origin, accessory.frame.insetBy(dx: -6, dy: -6).contains(point) {
            delegate.pageRowView(self, didRequestOriginOf: origin)
        } else if let id = openedNoun(at: point) {
            opened = id
        } else {
            switch model.action {
            case .toggle(let id, _):
                delegate.pageRowView(self, didToggleDisclosureOf: id, inAllRuns: event.modifierFlags.contains(.option))
            case .open(let id): opened = id
            case .none: break
            }
        }
        guard let opened else { return super.mouseDown(with: event) }
        // A press that opens a document stops here: the focus goes to it.
        delegate.pageRowView(self, didRequestDocument: opened, pinned: event.clickCount == 2)
    }

    /// The id a named file under `point` opens, when it is a link.
    private func openedNoun(at point: NSPoint) -> String? {
        let rect = wordsView.summary
        guard rect.contains(point) else { return nil }
        let storage = NSTextStorage(attributedString: summaryText)
        let container = NSTextContainer(size: NSSize(width: rect.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let inText = NSPoint(x: point.x - rect.minX, y: point.y - rect.minY)
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
