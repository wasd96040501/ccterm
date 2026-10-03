import AppKit
import DisplayModels

/// Lines of monospaced text with a tertiary line-number gutter — the body
/// of a command's output and of a file, read, created or changed
/// (02-command.md "Output", 03-file.md). Selectable, and searchable with ⌘F.
///
/// Shared by `CommandDocumentViewController` and
/// `SourceDocumentViewController`: they differ in what they put in the
/// lines — numbers, washes, change bars — not in how lines are set.
///
/// Three views side by side in one scroll: a `header` above, then the gutter
/// and the text. Only the text is text: one `NSTextView`, so selection, copy
/// and the find bar are the system's, and a selection or a click can reach
/// neither the gutter (Xcode's) nor the header. The gutter floats sideways
/// (`addFloatingSubview(_:for: .horizontal)`): a file scrolled sideways keeps
/// its numbers where they are.
@MainActor
final class NumberedLinesView: NSView {
    /// One line: what it says and how it is set apart.
    struct Line: Equatable {
        enum Kind: Equatable {
            case text
            /// A line the change puts in: green wash.
            case added
            /// A line the change takes out: red wash.
            case removed
            /// Lines left out: a quiet band; `text` says how many.
            case fold
            /// A heading with a hairline after it (*stderr*).
            case divider
        }

        var kind: Kind = .text
        /// Shown in the gutter; `nil` for none (a removed line).
        var number: Int?
        var text: String
        var spans: [LineSpan] = []
        /// The characters that differ, washed again inside a changed line.
        var changed: [Range<Int>] = []
        /// The number is drawn in the failure colour: a line that says so.
        var numberIsError = false
    }

    /// How the lines sit: a file has a fixed gutter and never wraps; output is
    /// a page — indented like the text above it, wrapping at the edge.
    enum Style: Equatable {
        case source
        case output
    }

    /// A 4-pt track down the right edge standing for a whole file, the part
    /// read filled in; fractions of the file.
    struct FileMap: Equatable {
        var start: Double
        var length: Double
    }

    struct Content: Equatable {
        var lines: [Line]
        var style: Style
        /// The change bar at the gutter's leading edge.
        var bar: ChangeBar?
        var fileMap: FileMap?
        /// The line to bring a third of the way down when the view first has
        /// its size — the first change.
        var revealLine: Int?
    }

    /// What stands above the first line and scrolls with it: the command
    /// page's heading, status and card, a change's notes. Laid out at the
    /// lines' width and measured; the lines start below it.
    var header: NSView? {
        get { document.header }
        set {
            document.header = newValue
            if let content { apply(content) }
        }
    }

    private var content: Content?
    private var pendingReveal: Int?
    private var revealScheduled = false

    private lazy var textView = LinesTextView()
    private lazy var gutter = GutterView(textView: textView)
    private lazy var document = LinesDocumentView(textView: textView, gutter: gutter)

    private lazy var scrollView: NSScrollView = {
        let scroll = OverlayScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.borderType = .noBorder
        // The gutter floats outside the clip view and is as tall as the
        // lines: unclipped, it scrolls up over whatever stands above.
        scroll.clipsToBounds = true
        scroll.documentView = document
        scroll.addFloatingSubview(gutter, for: .horizontal)
        return scroll
    }()

    private lazy var fileMapView: FileMapView = {
        let map = FileMapView()
        map.translatesAutoresizingMaskIntoConstraints = false
        map.isHidden = true
        return map
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureHierarchy()
        configureConstraints()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func configureHierarchy() {
        addSubview(scrollView)
        addSubview(fileMapView)
    }

    private func configureConstraints() {
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            fileMapView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            fileMapView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            fileMapView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            fileMapView.widthAnchor.constraint(equalToConstant: 4),
        ])
    }

    // MARK: - Content

    /// Sets the lines. Idempotent: the same content again changes nothing,
    /// and the scroll position stays.
    func configure(with content: Content) {
        guard content != self.content else { return }
        self.content = content
        apply(content)
        pendingReveal = content.revealLine
    }

    private func apply(_ content: Content) {
        let metrics = Metrics(content)
        scrollView.hasHorizontalScroller = !metrics.wraps
        scrollView.hasVerticalScroller = content.fileMap == nil
        // A header ends in its own margin; the text's top margin is for a page without one.
        textView.set(content.lines, metrics: metrics, topInset: header == nil ? metrics.top : 0)
        gutter.set(content.lines, metrics: metrics, bar: content.bar)
        document.gutterWidth = metrics.gutterWidth
        fileMapView.isHidden = content.fileMap == nil
        fileMapView.fileMap = content.fileMap
        needsLayout = true
    }

    override func layout() {
        super.layout()
        document.minimumSize = scrollView.contentSize
        revealIfPending()
    }

    /// Brings the first change a third of the way down, not to the top: the
    /// eye wants context above.
    private func revealIfPending() {
        guard pendingReveal != nil, window != nil, scrollView.contentSize.height > 0, !revealScheduled else { return }
        // After this layout pass, when the sizes are the final ones.
        revealScheduled = true
        DispatchQueue.main.async { [weak self] in self?.reveal() }
    }

    private func reveal() {
        revealScheduled = false
        guard let line = pendingReveal else { return }
        pendingReveal = nil
        scrollView.layoutSubtreeIfNeeded()
        guard let top = textView.top(ofLine: line) else { return }
        let y = textView.frame.minY + top
        let visible = scrollView.contentSize.height
        let maximum = max(0, document.frame.height - visible)
        // Already showing it, or the whole file fits: leave the scroll where it is.
        guard y - visible / 3 > 0, maximum > 0 else { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(y - visible / 3, maximum)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { needsLayout = true }
    }
}

// MARK: - Metrics

/// Where things sit, per style (preview.css `.src`, `.out`): the gutter's
/// width is where the text starts.
private struct Metrics {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let digitWidth: CGFloat = NSAttributedString(string: "0", attributes: [.font: font]).size().width

    var gutterWidth: CGFloat
    /// Output wraps at the edge; a file never does and scrolls sideways.
    var wraps: Bool
    /// The right edge the numbers are set against.
    var numberRight: CGFloat
    /// The change bar's x, when there is one.
    var barX: CGFloat?
    var rightPad: CGFloat
    /// Above the first line when nothing stands there.
    var top: CGFloat
    /// Below the last line.
    var bottom: CGFloat

    init(_ content: NumberedLinesView.Content) {
        switch content.style {
        case .source:
            self.init(gutterWidth: 61, wraps: false, numberRight: 44, barX: 2, rightPad: 16, top: 8, bottom: 24)
        case .output:
            let digits = max(String(content.lines.compactMap(\.number).max() ?? 0).count, 2)
            let numbers = ceil(Self.digitWidth * CGFloat(digits))
            self.init(
                gutterWidth: 24 + numbers + 14, wraps: true, numberRight: 24 + numbers, barX: nil, rightPad: 24, top: 0,
                bottom: 28)
        }
    }

    private init(
        gutterWidth: CGFloat, wraps: Bool, numberRight: CGFloat, barX: CGFloat?, rightPad: CGFloat, top: CGFloat,
        bottom: CGFloat
    ) {
        self.gutterWidth = gutterWidth
        self.wraps = wraps
        self.numberRight = numberRight
        self.barX = barX
        self.rightPad = rightPad
        self.top = top
        self.bottom = bottom
    }
}

/// The wash a line's kind lays across the gutter and the text alike.
extension NumberedLinesView.Line.Kind {
    fileprivate var wash: NSColor? {
        switch self {
        case .added: .addedLineWash
        case .removed: .removedLineWash
        case .fold: .tertiarySystemFill
        case .text, .divider: nil
        }
    }

    /// The wash behind the characters that differ inside a changed line.
    fileprivate var changedWash: NSColor {
        self == .removed
            ? .wash(.systemRed, light: 0.26, dark: 0.32) : .wash(.systemGreen, light: 0.34, dark: 0.34)
    }

    fileprivate var isChange: Bool { self == .added || self == .removed }
}

// MARK: - The document

/// What scrolls: the header on top, the text under it at the gutter's width
/// from the left edge, and room for the gutter, which floats beside the text
/// in the scroll view. Sized by hand, as a scroll view's document is: as wide
/// as the widest of the view and the longest unwrapped line, as tall as the
/// header and the text.
private final class LinesDocumentView: NSView {
    var header: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            headerWidth = nil
            if let header {
                header.translatesAutoresizingMaskIntoConstraints = false
                addSubview(header)
                let width = header.widthAnchor.constraint(equalToConstant: max(bounds.width, 1))
                headerWidth = width
                NSLayoutConstraint.activate([
                    header.leadingAnchor.constraint(equalTo: leadingAnchor),
                    header.topAnchor.constraint(equalTo: topAnchor),
                    width,
                ])
            }
            needsLayout = true
        }
    }

    var gutterWidth: CGFloat = 0 {
        didSet { needsLayout = true }
    }

    /// The scroll view's visible size: the document is never smaller.
    var minimumSize = NSSize.zero {
        didSet {
            guard minimumSize != oldValue else { return }
            arrange()
        }
    }

    private let textView: LinesTextView
    private let gutter: GutterView
    private var headerWidth: NSLayoutConstraint?

    init(textView: LinesTextView, gutter: GutterView) {
        self.textView = textView
        self.gutter = gutter
        super.init(frame: .zero)
        addSubview(textView)
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(textDidResize), name: NSView.frameDidChangeNotification, object: textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }

    /// A header that grows or shrinks by itself (a folded card opening)
    /// moves the lines with it.
    override func layout() {
        super.layout()
        arrange()
    }

    /// The text grows as its layout proceeds.
    @objc private func textDidResize() {
        arrange()
    }

    /// Nothing is sized before the scroll view has a size to size it to: a
    /// width on the way there would wrap the text once for nothing.
    private func arrange() {
        guard minimumSize.width > 0 else { return }
        let width = max(minimumSize.width, gutterWidth + textView.neededWidth)
        var top: CGFloat = 0
        if let header, let headerWidth {
            if abs(headerWidth.constant - width) > 0.5 { headerWidth.constant = width }
            header.layoutSubtreeIfNeeded()
            top = ceil(header.fittingSize.height)
        }
        let textFrame = NSRect(
            x: gutterWidth, y: top, width: width - gutterWidth, height: textView.frame.height)
        if textView.frame != textFrame { textView.frame = textFrame }
        // The gutter's frame is in the document's coordinates; the scroll
        // view keeps it at the left edge while the text scrolls sideways.
        let gutterFrame = NSRect(x: 0, y: top, width: gutterWidth, height: textView.frame.height)
        if gutter.frame != gutterFrame { gutter.frame = gutterFrame }
        gutter.needsDisplay = true
        let size = NSSize(width: width, height: max(minimumSize.height, top + textView.frame.height))
        if frame.size != size { setFrameSize(size) }
    }
}

// MARK: - The text

/// The lines, set as paragraphs, and their washes painted behind the text.
private final class LinesTextView: NSTextView, NSLayoutManagerDelegate {
    private static let captionFont = NSFont.systemFont(ofSize: 11)

    /// The width that fits the longest line without wrapping; `0` for output,
    /// which wraps.
    private(set) var neededWidth: CGFloat = 0

    /// Called when the lines have been laid out again: the gutter follows.
    var didLayOut: (() -> Void)?

    private(set) var lines: [NumberedLinesView.Line] = []
    private var starts: [Int] = []
    private var lengths: [Int] = []
    private var metrics: Metrics?
    private var baselineFromTop: CGFloat = 14

    init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        layoutManager.delegate = self
        isEditable = false
        isSelectable = true
        // Rich, so per-line paragraph styles survive; it is still read-only.
        isRichText = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        isHorizontallyResizable = false
        isVerticallyResizable = true
        autoresizingMask = []
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: Setting

    func set(_ lines: [NumberedLinesView.Line], metrics: Metrics, topInset: CGFloat) {
        self.lines = lines
        self.metrics = metrics
        let longest = lines.map { $0.text.utf16.count }.max() ?? 0
        neededWidth = metrics.wraps ? 0 : ceil(CGFloat(longest + 2) * Metrics.digitWidth) + metrics.rightPad
        textContainerInset = NSSize(width: 0, height: topInset)
        let text = NSMutableAttributedString()
        starts = []
        lengths = []
        for (index, line) in lines.enumerated() {
            starts.append(text.length)
            let paragraph = attributed(line, isLast: index == lines.count - 1, metrics: metrics, topInset: topInset)
            lengths.append(paragraph.length)
            text.append(paragraph)
        }
        textStorage?.setAttributedString(text)
        setSelectedRange(NSRange(location: 0, length: 0))
        needsDisplay = true
    }

    private func attributed(
        _ line: NumberedLinesView.Line, isLast: Bool, metrics: Metrics, topInset: CGFloat
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.tailIndent = -metrics.rightPad
        var font = Metrics.font
        var color = NSColor.labelColor
        var height: CGFloat = 18
        switch line.kind {
        case .fold:
            font = Self.captionFont
            color = .tertiaryLabelColor
            height = 22
            paragraph.paragraphSpacingBefore = 2
            paragraph.paragraphSpacing = 2
        case .divider:
            font = Self.captionFont
            color = .secondaryLabelColor
            height = 16
            paragraph.paragraphSpacingBefore = 16
            paragraph.paragraphSpacing = 6
        case .text, .added, .removed: break
        }
        paragraph.minimumLineHeight = height
        paragraph.maximumLineHeight = height
        if isLast { paragraph.paragraphSpacing += max(0, metrics.bottom - topInset) }
        let displayed = line.kind == .fold ? "⋯ " + line.text : line.text
        let shift = line.kind == .fold ? 2 : 0
        let string = NSMutableAttributedString(
            string: displayed + "\n",
            attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
                .baselineOffset: Self.baselineShift(for: font, height: height),
            ])
        string.apply(line.spans, at: shift, size: 12)
        for range in line.changed {
            let nsRange = NSRange(location: range.lowerBound + shift, length: range.count)
            guard NSMaxRange(nsRange) <= string.length else { continue }
            string.addAttribute(.backgroundColor, value: line.kind.changedWash, range: nsRange)
        }
        return string
    }

    /// A fixed line height puts the extra room above the text; half of it is
    /// given back so the text sits in the middle of its line.
    private static func baselineShift(for font: NSFont, height: CGFloat) -> CGFloat {
        let natural = ceil(font.ascender - font.descender + font.leading)
        return max(0, (height - natural) / 2)
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?,
        atEnd layoutFinishedFlag: Bool
    ) {
        didLayOut?()
    }

    // MARK: Geometry

    struct Placement {
        var top: CGFloat
        var bottom: CGFloat
        var baseline: CGFloat
    }

    private func paragraph(containing character: Int) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= character { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Where line `index` sits, in this view's coordinates.
    func placement(of index: Int) -> Placement? {
        guard index >= 0, index < lines.count, lengths[index] > 0, let layoutManager else { return nil }
        let characters = NSRange(location: starts[index], length: lengths[index])
        let glyphs = layoutManager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let origin = textContainerOrigin
        let first = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let last = layoutManager.lineFragmentUsedRect(
            forGlyphAt: glyphs.location + glyphs.length - 1, effectiveRange: nil)
        // A blank line's only glyph is its newline, which sits differently:
        // it borrows the offset of the last line that had text.
        let isBlank = lengths[index] == 1
        if !isBlank { baselineFromTop = layoutManager.location(forGlyphAt: glyphs.location).y + first.minY - used.minY }
        let baseline =
            isBlank ? used.minY + baselineFromTop : first.minY + layoutManager.location(forGlyphAt: glyphs.location).y
        return Placement(top: used.minY + origin.y, bottom: last.maxY + origin.y, baseline: baseline + origin.y)
    }

    /// The y of the top of line `index`.
    func top(ofLine index: Int) -> CGFloat? {
        placement(of: index)?.top
    }

    /// The lines any part of which is in `rect`, in this view's coordinates.
    func visibleLines(in rect: NSRect) -> Range<Int> {
        guard let layoutManager, let textContainer, !lines.isEmpty else { return 0..<0 }
        let origin = textContainerOrigin
        let inContainer = rect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: inContainer, in: textContainer)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let first = paragraph(containing: characters.location)
        let last = paragraph(containing: max(characters.location, NSMaxRange(characters) - 1))
        return first..<(last + 1)
    }

    // MARK: Drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let textContainer, let metrics else { return }
        for index in visibleLines(in: rect) {
            guard let place = placement(of: index) else { continue }
            let band = NSRect(x: 0, y: place.top, width: bounds.width, height: place.bottom - place.top)
            if let wash = lines[index].kind.wash {
                wash.setFill()
                band.fill()
            }
            guard lines[index].kind == .divider else { continue }
            let glyphs = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: starts[index], length: lengths[index] - 1),
                actualCharacterRange: nil)
            let text = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            let x = text.maxX + textContainerOrigin.x + 10
            NSColor.separatorColor.setFill()
            NSRect(
                x: x, y: (place.top + place.bottom) / 2 - 0.25, width: max(0, bounds.width - metrics.rightPad - x),
                height: 0.5
            )
            .fill()
        }
    }
}

// MARK: - The gutter

/// Numbers, right-aligned on each line's own baseline, the washes' share of
/// the gutter, and the change bar at its leading edge. Not text: nothing in
/// it is selected, copied or found, and a click in it starts no selection.
private final class GutterView: NSView {
    private let textView: LinesTextView
    private var lines: [NumberedLinesView.Line] = []
    private var metrics: Metrics?
    private var bar: ChangeBar?

    init(textView: LinesTextView) {
        self.textView = textView
        super.init(frame: .zero)
        // It paints an opaque background, which must stop at its edge: the
        // text scrolls under it sideways.
        clipsToBounds = true
        textView.didLayOut = { [weak self] in self?.needsDisplay = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }

    func set(_ lines: [NumberedLinesView.Line], metrics: Metrics, bar: ChangeBar?) {
        self.lines = lines
        self.metrics = metrics
        self.bar = bar
        needsDisplay = true
    }

    /// The text's lines share this view's y: both start under the header.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.intersection(bounds).fill()
        guard let metrics, lines.count == textView.lines.count else { return }
        for index in textView.visibleLines(in: NSRect(x: 0, y: dirtyRect.minY, width: 1, height: dirtyRect.height)) {
            guard let place = textView.placement(of: index) else { continue }
            let line = lines[index]
            let band = NSRect(x: 0, y: place.top, width: bounds.width, height: place.bottom - place.top)
            if let wash = line.kind.wash {
                wash.setFill()
                band.fill()
            }
            if let barX = metrics.barX { drawBar(at: barX, index: index, in: band) }
            guard let number = line.number, line.kind != .fold, line.kind != .divider else { continue }
            let string = NSAttributedString(
                string: String(number),
                attributes: [
                    .font: Metrics.font,
                    .foregroundColor: line.numberIsError ? NSColor.failureText : NSColor.tertiaryLabelColor,
                ])
            string.draw(
                at: NSPoint(x: metrics.numberRight - string.size().width, y: place.baseline - Metrics.font.ascender))
        }
    }

    /// Whether line `index` carries the bar.
    private func hasBar(_ index: Int) -> Bool {
        guard lines.indices.contains(index) else { return false }
        switch bar {
        case nil: return false
        case .hunks: return lines[index].kind.isChange
        case .wholeFile: return lines[index].kind != .fold
        }
    }

    /// One line's part of the bar: a run of lines is one bar.
    private func drawBar(at x: CGFloat, index: Int, in band: NSRect) {
        guard let bar, hasBar(index) else { return }
        bar.draw(
            NSRect(x: x, y: band.minY, width: ChangeBar.width, height: band.height),
            joinsAbove: hasBar(index - 1), joinsBelow: hasBar(index + 1))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - The scroll view

/// Overlay scrollers, hidden until scrolling, whatever the system setting —
/// as the transcript's (design/transcript/README.md "Scrollers"): a scroller
/// never takes width, so lines never rewrap when one appears. Overridden both
/// ways, the AppKit recipe for pinning it: AppKit writes the system's style
/// here whenever the setting changes, and reads it back to decide whether the
/// scroller takes room from the clip view.
private final class OverlayScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }
}

// MARK: - The file map

/// The read slice of a file, as a track down the right edge.
private final class FileMapView: NSView {
    var fileMap: NumberedLinesView.FileMap? {
        didSet {
            needsLayout = true
            needsDisplay = true
        }
    }

    private let slice = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 2
        slice.cornerRadius = 2
        layer?.addSublayer(slice)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
            slice.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.75).cgColor
        }
    }

    override func layout() {
        super.layout()
        guard let fileMap else { return }
        let height = max(bounds.height * fileMap.length, bounds.height * 0.015)
        let top = min(bounds.height * fileMap.start, bounds.height - height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        slice.frame = NSRect(x: 0, y: top, width: bounds.width, height: height)
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
