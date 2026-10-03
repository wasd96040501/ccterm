import AppKit

/// What the field reports to the composer: its words changed, the focus moved,
/// or a key the composer decides.
@MainActor
protocol ComposerFieldViewDelegate: AnyObject {
    func composerFieldViewDidChange(_ field: ComposerFieldView)
    func composerFieldView(_ field: ComposerFieldView, didChangeFocus isFocused: Bool)
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
        /// ⌘. (the Mac's Cancel).
        case stop
    }

    weak var delegate: ComposerFieldViewDelegate?

    static let font = NSFont.systemFont(ofSize: 14)
    static let lineHeight: CGFloat = 22
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

    /// The words after the token.
    var body: String {
        get { textView.string }
        set {
            textView.string = newValue
            textDidChange()
        }
    }

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
        view.textContainerInset = NSSize(width: 0, height: Self.topInset)
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        let style = NSMutableParagraphStyle()
        style.lineSpacing = Self.lineSpacing
        view.defaultParagraphStyle = style
        view.typingAttributes = [
            .font: Self.font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
        ]
        view.delegate = self
        view.onFocusChange = { [weak self] focused in
            guard let self else { return }
            self.delegate?.composerFieldView(self, didChangeFocus: focused)
        }
        return view
    }()

    private lazy var scrollView: NSScrollView = {
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }()

    private let tokenView = CommandTokenView()
    private lazy var heightConstraint = scrollView.heightAnchor.constraint(equalToConstant: Self.lineHeight)
    private lazy var plainLeading = scrollView.leadingAnchor.constraint(equalTo: leadingAnchor)
    private lazy var tokenLeading = scrollView.leadingAnchor.constraint(equalTo: tokenView.trailingAnchor, constant: 6)

    /// The line's 22 pt less the font's own height, added after each line.
    private static var lineSpacing: CGFloat {
        let font = Self.font
        return max(0, lineHeight - (font.ascender - font.descender + font.leading))
    }

    /// Centres the 14-pt text in its 22-pt line.
    private static var topInset: CGFloat { (lineSpacing / 2).rounded(.down) }

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
            heightConstraint,
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

    var isFocused: Bool { window?.firstResponder === textView }

    // MARK: - Sizing

    /// The field is as tall as its text, from one line up to eight.
    private var wantedHeight: CGFloat {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else {
            return Self.lineHeight
        }
        layoutManager.ensureLayout(for: container)
        let used = ceil(layoutManager.usedRect(for: container).height)
        let text = used + Self.lineSpacing / 2 + Self.topInset
        return min(max(text, Self.lineHeight), Self.lineHeight * CGFloat(Self.maxLines))
    }

    override func layout() {
        super.layout()
        // A change of width rewraps the text; follow it.
        let wanted = wantedHeight
        if abs(heightConstraint.constant - wanted) > 0.5 {
            heightConstraint.constant = wanted
            super.layout()
        }
    }

    private func textDidChange() {
        textView.needsDisplay = true
        heightConstraint.constant = wantedHeight
        delegate?.composerFieldViewDidChange(self)
    }
}

extension ComposerFieldView: NSTextViewDelegate {
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
            // ⌘. and ⎋ both arrive here; ⎋ belongs to the permission card.
            if flags.contains(.command), event?.charactersIgnoringModifiers == "." {
                return delegate?.composerFieldView(self, handle: .stop) ?? false
            }
            return delegate?.composerFieldView(self, handle: .escape) ?? false
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
    var onFocusChange: ((Bool) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), !hidesPlaceholder else { return }
        let origin = NSPoint(x: textContainerInset.width, y: textContainerInset.height)
        (placeholder as NSString).draw(
            at: origin,
            withAttributes: [.font: ComposerFieldView.font, .foregroundColor: NSColor.tertiaryLabelColor])
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            needsDisplay = true
            onFocusChange?(true)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
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
        layer?.cornerRadius = 5
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
