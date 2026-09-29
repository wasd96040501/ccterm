import AppKit

/// Lines of monospaced text with a tertiary line-number gutter — the body
/// of a command's output and of a file, read, created or changed
/// (02-command.md "Output", 03-file.md). Selectable, and searchable with ⌘F.
///
/// Shared by `CommandDocumentViewController` and
/// `SourceDocumentViewController`: they differ in what they put in the
/// lines — numbers, washes, change bars — not in how lines are set.
///
/// One `NSTextView` in one `NSScrollView`, so selection, copy and the find
/// bar are the system's. The gutter is drawn in the text view's own margin
/// (each paragraph is indented past it), which keeps a `header` above the
/// lines in the same scroll and the same coordinates.
@MainActor
final class NumberedLinesView: NSView {
    /// One line: what it says and how it is set apart.
    struct Line: Equatable {
        enum Kind: Equatable {
            case text
            /// A line the change puts in: green wash.
            case added
            /// A line the change takes out: red wash, secondary text.
            case removed
            /// Lines left out: a quiet band; `text` says how many.
            case fold
            /// A heading with a hairline after it (*stderr*).
            case divider
            /// Room for the `header`; the view puts it there itself.
            case spacer
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

    /// The 3-pt bar beside the gutter.
    enum Bar: Equatable {
        case none
        /// In Xcode's source-control blue, on each changed line.
        case hunks
        /// In green, the file's full height: all of it is new.
        case wholeFile
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
        var bar: Bar = .none
        var fileMap: FileMap?
        /// The line to bring a third of the way down when the view first has
        /// its size — the first change.
        var revealLine: Int?
    }

    /// What stands above the first line and scrolls with it: the command
    /// page's heading, status and card. Laid out at the view's width and
    /// measured; the lines start below it.
    var header: NSView? {
        didSet { textView.header = header }
    }

    private var content: Content?
    private var pendingReveal: Int?
    private var revealScheduled = false

    private lazy var textView: LinesTextView = {
        let view = LinesTextView()
        view.isEditable = false
        view.isSelectable = true
        // Rich, so per-line paragraph styles survive; it is still read-only.
        view.isRichText = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.drawsBackground = true
        view.backgroundColor = .textBackgroundColor
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        return view
    }()

    private lazy var scrollView: NSScrollView = {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        // A legacy scroller keeps its track even while the lines fit: one that
        // appears once they overflow narrows the text and rewraps every line
        // on screen — as a live command's output grows past the fold.
        scroll.autohidesScrollers = false
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.borderType = .noBorder
        scroll.documentView = textView
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
        let wraps = content.style == .output
        scrollView.hasHorizontalScroller = !wraps
        scrollView.hasVerticalScroller = content.fileMap == nil
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = []
        textView.set(content)
        fileMapView.isHidden = content.fileMap == nil
        fileMapView.fileMap = content.fileMap
        pendingReveal = content.revealLine
        needsLayout = true
    }

    override func layout() {
        super.layout()
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        // A file never wraps: the text view is as wide as its longest line
        // and the scroll view scrolls sideways; output is as wide as the pane.
        let width = max(scrollView.contentSize.width, textView.neededWidth)
        if abs(textView.frame.width - width) > 0.5 {
            textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
        }
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
        let visible = scrollView.contentSize.height
        let maximum = max(0, textView.frame.height - visible)
        // Already showing it, or the whole file fits: leave the scroll where it is.
        guard top - visible / 3 > 0, maximum > 0 else { return }
        let y = min(top - visible / 3, maximum)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { needsLayout = true }
    }
}

// MARK: - The text

/// The lines, set: paragraphs indented past a drawn gutter, washes and the
/// gutter painted around the text.
private final class LinesTextView: NSTextView {
    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let captionFont = NSFont.systemFont(ofSize: 11)

    /// Where things sit in a line, per style (preview.css `.src`, `.out`).
    private struct Metrics {
        var numberRight: CGFloat
        var barX: CGFloat?
        var textX: CGFloat
        var leftPad: CGFloat
        var rightPad: CGFloat
        var top: CGFloat
        var bottom: CGFloat
    }

    /// The width that fits the longest line without wrapping; `0` for output,
    /// which wraps.
    private(set) var neededWidth: CGFloat = 0

    private var baselineFromTop: CGFloat = 14
    private var lines: [NumberedLinesView.Line] = []
    private var starts: [Int] = []
    private var lengths: [Int] = []
    private var metrics = Metrics(numberRight: 44, barX: 46, textX: 61, leftPad: 0, rightPad: 16, top: 8, bottom: 24)
    private var bar = NumberedLinesView.Bar.none
    private var wraps = false

    var header: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            headerWidth = nil
            guard let header else {
                spacerHeight = 0
                rebuild()
                return
            }
            header.translatesAutoresizingMaskIntoConstraints = false
            addSubview(header)
            let width = header.widthAnchor.constraint(equalToConstant: max(bounds.width, 1))
            headerWidth = width
            NSLayoutConstraint.activate([
                header.leadingAnchor.constraint(equalTo: leadingAnchor),
                header.topAnchor.constraint(equalTo: topAnchor),
                width,
            ])
            updateHeader()
            rebuild()
        }
    }
    private var headerWidth: NSLayoutConstraint?
    /// The height of the leading line that keeps the text below the header.
    private var spacerHeight: CGFloat = 0
    private var content: NumberedLinesView.Content?
    private var lineOffset: Int { header == nil ? 0 : 1 }

    init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: Setting

    func set(_ content: NumberedLinesView.Content) {
        self.content = content
        rebuild()
    }

    private func rebuild() {
        guard let content else { return }
        lines = (header == nil ? [] : [NumberedLinesView.Line(kind: .spacer, text: "")]) + content.lines
        bar = content.bar
        wraps = content.style == .output
        let digits = max(String(content.lines.compactMap(\.number).max() ?? 0).count, 2)
        switch content.style {
        case .source:
            metrics = Metrics(numberRight: 44, barX: 46, textX: 61, leftPad: 0, rightPad: 16, top: 8, bottom: 24)
        case .output:
            let numbers = ceil(Self.digitWidth * CGFloat(digits))
            metrics = Metrics(
                numberRight: 24 + numbers, barX: nil, textX: 24 + numbers + 14, leftPad: 24, rightPad: 24, top: 0,
                bottom: 28)
        }
        let longest = wraps ? 0 : content.lines.map { $0.text.utf16.count }.max() ?? 0
        neededWidth = wraps ? 0 : ceil(CGFloat(longest + 2) * Self.digitWidth) + metrics.textX + metrics.rightPad
        textContainerInset = NSSize(width: 0, height: header == nil ? metrics.top : 0)
        let text = NSMutableAttributedString()
        starts = []
        lengths = []
        for (index, line) in lines.enumerated() {
            starts.append(text.length)
            let paragraph = attributed(line, isLast: index == lines.count - 1)
            lengths.append(paragraph.length)
            text.append(paragraph)
        }
        textStorage?.setAttributedString(text)
        setSelectedRange(NSRange(location: 0, length: 0))
        needsDisplay = true
    }

    private static let digitWidth: CGFloat = NSAttributedString(string: "0", attributes: [.font: font]).size().width

    private func attributed(_ line: NumberedLinesView.Line, isLast: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.firstLineHeadIndent = line.kind == .divider ? metrics.leftPad : metrics.textX
        paragraph.headIndent = paragraph.firstLineHeadIndent
        paragraph.tailIndent = -metrics.rightPad
        var font = Self.font
        var color = NSColor.labelColor
        var height: CGFloat = 18
        switch line.kind {
        case .removed: color = .secondaryLabelColor
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
        case .spacer: height = max(spacerHeight, 1)
        case .text, .added: break
        }
        paragraph.minimumLineHeight = height
        paragraph.maximumLineHeight = height
        if isLast { paragraph.paragraphSpacing += max(0, metrics.bottom - textContainerInset.height) }
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

    // MARK: Header

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateHeader()
    }

    /// A header that grows or shrinks by itself (a folded card opening)
    /// moves the lines with it.
    override func layout() {
        super.layout()
        updateHeader()
    }

    /// The header at the view's width, and the lines pushed below it.
    private func updateHeader() {
        guard let header, let headerWidth else { return }
        headerWidth.constant = max(bounds.width, 1)
        header.layoutSubtreeIfNeeded()
        let height = ceil(header.fittingSize.height)
        if lines.first?.kind == .spacer { applyExclusion(height: height) } else { spacerHeight = height }
    }

    /// Sets the height of the line that holds the header's place.
    private func applyExclusion(height: CGFloat) {
        guard abs(height - spacerHeight) > 0.5, lines.first?.kind == .spacer else { return }
        spacerHeight = height
        rebuild()
    }

    // MARK: Geometry

    private func paragraph(containing character: Int) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= character { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private struct Placement {
        var top: CGFloat
        var bottom: CGFloat
        var baseline: CGFloat
        var firstFragment: NSRect
    }

    private func placement(of index: Int) -> Placement? {
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
        return Placement(
            top: used.minY + origin.y, bottom: last.maxY + origin.y, baseline: baseline + origin.y,
            firstFragment: first.offsetBy(dx: origin.x, dy: origin.y))
    }

    /// The y of the top of line `index`.
    func top(ofLine index: Int) -> CGFloat? {
        placement(of: index + lineOffset)?.top
    }

    private func visibleLines(in rect: NSRect) -> Range<Int> {
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
        guard let layoutManager, let textContainer else { return }
        for index in visibleLines(in: rect) {
            guard let place = placement(of: index) else { continue }
            let band = NSRect(
                x: 0, y: place.top, width: max(bounds.width, visibleRect.maxX), height: place.bottom - place.top)
            switch lines[index].kind {
            case .added:
                NSColor.wash(.systemGreen, light: 0.14, dark: 0.15).setFill()
                band.fill()
            case .removed:
                NSColor.wash(.systemRed, light: 0.10, dark: 0.14).setFill()
                band.fill()
            case .fold:
                NSColor.tertiarySystemFill.setFill()
                band.fill()
            case .divider:
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
            case .text, .spacer:
                break
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawGutter(in: dirtyRect)
    }

    /// Numbers, right-aligned to the gutter's edge on each line's own
    /// baseline, and the change bar. Kept at the left edge of what is showing
    /// when the lines are scrolled sideways.
    private func drawGutter(in dirtyRect: NSRect) {
        let inset = wraps ? 0 : visibleRect.minX
        if inset > 0 {
            NSColor.textBackgroundColor.setFill()
            NSRect(x: inset, y: dirtyRect.minY, width: metrics.textX - 4, height: dirtyRect.height).fill()
        }
        let numberFont = Self.font
        for index in visibleLines(in: dirtyRect) {
            guard let place = placement(of: index) else { continue }
            let line = lines[index]
            if let barX = metrics.barX, let color = barColor(for: line.kind) {
                color.setFill()
                NSRect(x: inset + barX, y: place.top, width: 3, height: place.bottom - place.top).fill()
            }
            guard let number = line.number, line.kind != .fold, line.kind != .divider else { continue }
            let string = NSAttributedString(
                string: String(number),
                attributes: [
                    .font: numberFont,
                    .foregroundColor: line.numberIsError ? NSColor.failureText : NSColor.tertiaryLabelColor,
                ])
            let width = string.size().width
            string.draw(at: NSPoint(x: inset + metrics.numberRight - width, y: place.baseline - numberFont.ascender))
        }
    }

    private func barColor(for kind: NumberedLinesView.Line.Kind) -> NSColor? {
        switch bar {
        case .none: nil
        case .wholeFile: kind == .fold ? nil : NSColor.systemGreen.withAlphaComponent(0.7)
        case .hunks: kind == .added || kind == .removed ? .systemBlue : nil
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self)
        guard let clip = superview as? NSClipView else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: clip)
    }

    @objc private func scrolled() {
        if !wraps { needsDisplay = true }
    }
}

extension NumberedLinesView.Line.Kind {
    /// The wash behind the characters that differ inside a changed line.
    fileprivate var changedWash: NSColor {
        self == .removed
            ? .wash(.systemRed, light: 0.26, dark: 0.32) : .wash(.systemGreen, light: 0.34, dark: 0.34)
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
