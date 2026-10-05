import AppKit

/// What the field reports to the composer: its words changed, or a key the
/// composer decides.
@MainActor
protocol ComposerFieldViewDelegate: AnyObject {
    func composerFieldViewDidChange(_ field: ComposerFieldView)
    /// The reader pressed `key`; `true` when the composer took it.
    func composerFieldView(_ field: ComposerFieldView, handle key: ComposerFieldView.Key) -> Bool
}

/// The composer's writing place (design 08 *The composer*): a 14-pt field that
/// grows from one line to eight, with an optional command token before its
/// words — mono, on an inset wash, removed whole by backspace.
///
/// It owns the words and the token and says what the keys do to them; what
/// Return, ⇧⇥, ⌘. and the completion keys *mean* is the composer's
/// (`Key`, handled by its delegate first).
@MainActor
final class ComposerFieldView: NSView {
    /// A key the composer may take before the field acts on it.
    enum Key {
        /// ↩ without ⇧.
        case send
        case moveUp
        case moveDown
        /// ⇥: completes a command.
        case tab
        /// ⇧⇥.
        case backtab
        /// ⎋ — the field never takes it unless a list is open.
        case escape
    }

    weak var delegate: ComposerFieldViewDelegate?

    static let font = NSFont.systemFont(ofSize: 14)
    static let lineHeight: CGFloat = 22
    /// The field holds two lines before it grows, and eight before it scrolls.
    static let minLines = 2
    static let maxLines = 8

    /// What it says while empty.
    var placeholder = "" {
        didSet {
            textView.placeholder = placeholder
            textView.needsDisplay = true
        }
    }

    /// Whether the words (and the token) are drawn at half strength — a prompt
    /// that was sent and is not yet the session's (design 08, the handover:
    /// *textarea 50 %*). Display only; the words are untouched.
    var isDimmed = false {
        didSet {
            let alpha: CGFloat = isDimmed ? 0.5 : 1
            scrollView.alphaValue = alpha
            tokenView.alphaValue = alpha
        }
    }

    /// The command already completed in front of the words, without its `/`.
    private(set) var token: String?

    /// The words after the token. Setting them is no edit of the user's, so
    /// it clears what ⌘Z would undo.
    var body: String {
        get { textView.string }
        set {
            textView.string = newValue
            undo.removeAllActions()
            textDidChange()
        }
    }

    /// The text view's undo: the typing since the words or the token were
    /// last set, none of it replayed against words that are gone.
    private let undo = UndoManager()

    private lazy var textView: ComposerTextView = {
        let view = ComposerTextView(frame: .zero)
        view.font = Self.font
        view.textColor = .labelColor
        view.drawsBackground = false
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.defaultParagraphStyle = Self.lineStyle
        view.typingAttributes = Self.textAttributes
        view.delegate = self
        return view
    }()

    private lazy var scrollView: NSScrollView = {
        let scroll = OverlayScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }()

    private let tokenView = CommandTokenView()
    /// The field's height: its text's (`fitsText`), held between two lines
    /// and eight by required limits.
    private lazy var fitsText: NSLayoutConstraint = {
        let fits = scrollView.heightAnchor.constraint(equalToConstant: Self.lineHeight)
        fits.priority = .defaultHigh
        return fits
    }()
    private lazy var plainLeading = scrollView.leadingAnchor.constraint(equalTo: leadingAnchor)
    private lazy var tokenLeading = scrollView.leadingAnchor.constraint(equalTo: tokenView.trailingAnchor, constant: 6)

    /// Every line is 22 pt: the paragraph's line height, fixed.
    private static let lineStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        return style
    }()

    /// The words' attributes: 14 pt on the 22-pt line, the glyphs raised to
    /// its middle (a fixed line height puts its extra space over them).
    static let textAttributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: lineStyle,
        .baselineOffset: (lineHeight - (font.ascender - font.descender)) / 2,
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        tokenView.translatesAutoresizingMaskIntoConstraints = false
        tokenView.isHidden = true
        addSubview(tokenView)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            tokenView.leadingAnchor.constraint(equalTo: leadingAnchor),
            // `.cmdtok { margin-top: 2px }` on the field's first line.
            tokenView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.lineHeight * CGFloat(Self.minLines)),
            scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: Self.lineHeight * CGFloat(Self.maxLines)),
            fitsText,
            plainLeading,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - Words

    /// The command token, as `/name`, then the words.
    var fullText: String {
        guard let token else { return body }
        return body.isEmpty ? "/\(token)" : "/\(token) \(body)"
    }

    /// Whether there is anything to send.
    var hasContent: Bool {
        token != nil || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The command being typed — the text after a leading `/`, up to the first
    /// white space — while there is no token and no space yet; `nil` otherwise.
    var slashQuery: String? {
        guard token == nil, body.hasPrefix("/") else { return nil }
        let rest = body.dropFirst()
        return rest.contains(where: \.isWhitespace) ? nil : String(rest)
    }

    /// Sets the words, turning a leading `/name ` that `isCommand` knows into the token.
    func setText(_ text: String, isCommand: (String) -> Bool) {
        if text.hasPrefix("/") {
            let rest = text.dropFirst()
            let name = rest.prefix { !$0.isWhitespace }
            if !name.isEmpty, isCommand(String(name)) {
                let after = rest.dropFirst(name.count)
                setToken(String(name))
                body = String(after.drop(while: { $0 == " " }))
                return
            }
        }
        setToken(nil)
        body = text
    }

    /// Completes the command being typed: the token takes its place and the
    /// typed `/query` goes.
    func complete(command name: String) {
        setToken(name)
        body = ""
    }

    private func setToken(_ name: String?) {
        guard name != token else { return }
        token = name
        undo.removeAllActions()
        tokenView.isHidden = name == nil
        if let name { tokenView.name = name }
        plainLeading.isActive = name == nil
        tokenLeading.isActive = name != nil
        textView.hidesPlaceholder = name != nil
        textView.needsDisplay = true
        invalidateIntrinsicContentSize()
        delegate?.composerFieldViewDidChange(self)
    }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    // MARK: - Sizing

    /// How tall the text is: its lines, 22 pt each.
    private var textHeight: CGFloat {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else {
            return Self.lineHeight
        }
        layoutManager.ensureLayout(for: container)
        let used = ceil(layoutManager.usedRect(for: container).height)
        return used
    }

    override func layout() {
        super.layout()
        // A change of width rewraps the text; follow it.
        let height = textHeight
        if abs(fitsText.constant - height) > 0.5 {
            fitsText.constant = height
            super.layout()
        }
    }

    private func textDidChange() {
        textView.needsDisplay = true
        fitsText.constant = textHeight
        delegate?.composerFieldViewDidChange(self)
    }
}

extension ComposerFieldView: NSTextViewDelegate {
    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    func textDidChange(_ notification: Notification) {
        textDidChange()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let event = NSApp.currentEvent
        let flags = event?.modifierFlags ?? []
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            if flags.contains(.shift) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            return delegate?.composerFieldView(self, handle: .send) ?? false
        case #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            return false
        case #selector(NSResponder.moveUp(_:)):
            return delegate?.composerFieldView(self, handle: .moveUp) ?? false
        case #selector(NSResponder.moveDown(_:)):
            return delegate?.composerFieldView(self, handle: .moveDown) ?? false
        case #selector(NSResponder.insertTab(_:)):
            if delegate?.composerFieldView(self, handle: .tab) == true { return true }
            // A tab is not a character of a prompt: it moves on.
            window?.selectNextKeyView(nil)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            return delegate?.composerFieldView(self, handle: .backtab) ?? true
        case #selector(NSResponder.cancelOperation(_:)):
            // ⎋ closes the slash list; otherwise it goes up the responder
            // chain, never to the text view's completion list.
            if delegate?.composerFieldView(self, handle: .escape) == true { return true }
            nextResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil)
            return true
        case #selector(NSResponder.deleteBackward(_:)):
            // Backspace into the token removes it whole.
            if token != nil, textView.selectedRange() == NSRange(location: 0, length: 0) {
                setToken(nil)
                textDidChange()
                return true
            }
            return false
        default:
            return false
        }
    }
}

/// The field's text view: says what it is for while empty, and reports focus.
private final class ComposerTextView: NSTextView {
    var placeholder = ""
    var hidesPlaceholder = false

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), !hidesPlaceholder else { return }
        // On the first line, as the words would be.
        var attributes = ComposerFieldView.textAttributes
        attributes[.foregroundColor] = NSColor.tertiaryLabelColor
        (placeholder as NSString).draw(
            in: NSRect(x: 0, y: 0, width: bounds.width, height: ComposerFieldView.lineHeight),
            withAttributes: attributes)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { needsDisplay = true }
        return accepted
    }
}

/// `/name` as the field draws a completed command (preview-live.css
/// `.lv-field .cmdtok`): SF Mono 13 medium, the slash in secondary, on a
/// tertiary fill with 5-pt corners; 5 pt either side, and — the design's
/// `line-height: 1` — 13 pt of type with 2 above and below, 17 in all.
private final class CommandTokenView: NSView {
    static let height: CGFloat = 17

    var name = "" {
        didSet { label.attributedStringValue = Self.attributed(name) }
    }

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = CornerRadius.tag
        layer?.cornerCurve = .continuous
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private static func attributed(_ name: String) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        let text = NSMutableAttributedString(
            string: "/", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        text.append(NSAttributedString(string: name, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        return text
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.tertiarySystemFill.cgColor
        }
    }
}
