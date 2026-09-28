import AppKit

/// A read-only source editor, Xcode's: SF Mono in Xcode's default theme, a
/// gutter of line numbers, and — for a comparison — Xcode's inline comparison
/// (removed lines on red, added on green with the changed words marked, a
/// striped bar beside each change).
///
/// One view for a file, a comparison and command output alike, because to it
/// they are one thing: numbered lines, some of them changed, some of them
/// coloured. Text is selectable and copyable, and the system find bar (⌘F)
/// searches it; nothing edits it.
@MainActor
public final class SourceView: NSView {
    /// What is shown. Setting it restyles everything and scrolls to the top.
    public var document: SourceDocument {
        didSet {
            guard document != oldValue else { return }
            reload()
        }
    }

    /// Long lines wrap at the view's width, continuing indented past their
    /// own indentation, as Xcode's Wrap Lines does. Off, the view scrolls
    /// sideways.
    public var wrapsLines = true {
        didSet {
            guard wrapsLines != oldValue else { return }
            applyWrapping()
        }
    }

    private let scrollView = NSScrollView()
    private let textView: SourceTextView
    private let gutter: SourceGutterView
    private var styledAsDark: Bool?
    private lazy var gutterWidth = gutter.widthAnchor.constraint(equalToConstant: gutter.thickness)
    private var scrollObservation: NSObjectProtocol?

    public init(document: SourceDocument = SourceDocument(lines: [], language: .plainText)) {
        self.document = document
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 4
        layoutManager.addTextContainer(container)
        textView = SourceTextView(frame: .zero, textContainer: container)
        gutter = SourceGutterView(textView: textView)
        super.init(frame: .zero)
        configureTextView()
        configureScrollView()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - Measuring

    /// The editor's background, for a host that frames the view with its own
    /// panes.
    public static var backgroundColor: NSColor { SourceTheme.background }

    /// The height `lineCount` unwrapped lines take, insets included — for a
    /// host that sizes the view to a short text rather than a pane.
    public static func height(ofLines lineCount: Int) -> CGFloat {
        let line = NSLayoutManager().defaultLineHeight(for: SourceTheme.font(dark: false)) * SourceTheme.lineSpacing
        return ceil(CGFloat(lineCount) * line) + 8
    }

    // MARK: - Navigating

    /// Scrolls change `index` of ``SourceDocument/changes`` to a third of the
    /// way down, where Xcode puts the change its arrows step to.
    public func scrollToChange(at index: Int) {
        let changes = document.changes
        guard changes.indices.contains(index) else { return }
        scrollToLine(at: changes[index].lowerBound)
    }

    /// Scrolls line `index` (of the document's lines) to a third of the way
    /// down, or as near as the text allows.
    public func scrollToLine(at index: Int) {
        guard let layoutManager = textView.layoutManager, textView.lines.indices.contains(index) else { return }
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: textView.lineStarts[index] + 1))
        let rect = textView.rect(ofLine: index)
        let visible = scrollView.contentView.bounds
        let y = max(0, min(rect.minY - visible.height / 3, textView.bounds.height - visible.height))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - Building

    private func configureTextView() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = true
        textView.backgroundColor = SourceTheme.background
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.isAutomaticLinkDetectionEnabled = false
        textView.displaysLinkToolTips = false
        textView.selectedTextAttributes = [.backgroundColor: SourceTheme.selection]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.setAccessibilityLabel(String(localized: "Source", bundle: .module))
    }

    private func configureScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = SourceTheme.background
        scrollView.documentView = textView
        scrollView.findBarPosition = .aboveContent
        scrollView.contentView.postsBoundsChangedNotifications = true
        gutter.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gutter)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            gutter.topAnchor.constraint(equalTo: topAnchor),
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutter.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutterWidth,
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // Block-based: the token is released with this view, which ends the
        // observation — nothing else holds it.
        scrollObservation = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.gutter.needsDisplay = true }
        }
        applyWrapping()
    }

    private func applyWrapping() {
        guard let container = textView.textContainer else { return }
        if wrapsLines {
            scrollView.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            container.widthTracksTextView = true
            textView.frame.size.width = scrollView.contentSize.width
        } else {
            scrollView.hasHorizontalScroller = true
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = []
            container.widthTracksTextView = false
            container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }
        restyle()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Colours follow on their own; the faces differ by appearance.
        if styledAsDark != effectiveAppearance.isDark { restyle() }
    }

    private func reload() {
        textView.setLines(document.lines)
        restyle()
        gutter.updateThickness()
        gutterWidth.constant = gutter.thickness
        scrollView.contentView.scroll(to: .zero)
    }

    /// Everything the text storage holds: text, faces, colours, indents.
    private func restyle() {
        let dark = effectiveAppearance.isDark
        styledAsDark = dark
        let text = document.lines.map(\.text).joined(separator: "\n")
        let styled = Self.attributedText(text, document: document, dark: dark, wraps: wrapsLines)
        // Never `textView.font =` after this: it sets one face over the whole
        // storage, flattening keywords and documentation back to plain.
        textView.textStorage?.setAttributedString(styled)
        textView.plainFont = SourceTheme.font(dark: dark)
        textView.typingAttributes = [.font: SourceTheme.font(dark: dark), .foregroundColor: SourceTheme.plainText]
        gutter.needsDisplay = true
    }

    static func attributedText(
        _ text: String, document: SourceDocument, dark: Bool, wraps: Bool
    )
        -> NSAttributedString
    {
        let font = SourceTheme.font(dark: dark)
        let tabWidth = CGFloat(4) * ("M" as NSString).size(withAttributes: [.font: font]).width
        let base = NSMutableParagraphStyle()
        base.lineHeightMultiple = SourceTheme.lineSpacing
        base.defaultTabInterval = tabWidth
        base.tabStops = []
        let styled = NSMutableAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: SourceTheme.plainText, .paragraphStyle: base])
        styled.beginEditing()
        defer { styled.endEditing() }

        var offset = 0
        for line in document.lines {
            let length = line.text.utf16.count
            // Wrapped continuation lines hang past the line's own indent.
            if wraps, length > 0 {
                let indent = line.text.prefix { $0 == " " || $0 == "\t" }
                    .reduce(CGFloat(0)) { $0 + ($1 == "\t" ? 4 : 1) }
                let style = base.mutableCopy() as! NSMutableParagraphStyle
                style.headIndent = (indent + 4) * tabWidth / 4
                styled.addAttribute(.paragraphStyle, value: style, range: NSRange(location: offset, length: length))
            }
            offset += length + 1
        }

        for token in SyntaxHighlighter.tokens(in: text, language: document.language) {
            let range = NSRange(location: token.range.lowerBound, length: token.range.count)
            styled.addAttribute(.foregroundColor, value: SourceTheme.color(for: token.kind), range: range)
            let face = SourceTheme.font(for: token.kind, dark: dark)
            if face != font { styled.addAttribute(.font, value: face, range: range) }
        }

        offset = 0
        for line in document.lines {
            for run in line.styles {
                let range = NSRange(location: offset + run.range.lowerBound, length: run.range.count)
                if var color = run.foreground.map(SourceTheme.color(for:)) {
                    if run.isDim { color = color.withAlphaComponent(0.6) }
                    styled.addAttribute(.foregroundColor, value: color, range: range)
                } else if run.isDim {
                    styled.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
                }
                if let background = run.background {
                    styled.addAttribute(
                        .backgroundColor, value: SourceTheme.color(for: background).withAlphaComponent(0.3),
                        range: range)
                }
                if run.isBold {
                    styled.addAttribute(
                        .font, value: NSFont.monospacedSystemFont(ofSize: SourceTheme.fontSize, weight: .bold),
                        range: range)
                }
                if run.isItalic {
                    styled.addAttribute(.obliqueness, value: 0.15, range: range)
                }
                if run.isUnderlined {
                    styled.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                }
            }
            offset += line.text.utf16.count + 1
        }
        return styled
    }

    /// The tint a line of this kind is drawn on, across text and gutter.
    static func tint(for change: SourceLine.Change) -> NSColor? {
        switch change {
        case .unchanged: nil
        case .added: SourceTheme.addedBackground
        case .removed: SourceTheme.removedBackground
        case .elided: SourceTheme.elidedBackground
        }
    }
}
