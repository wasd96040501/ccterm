import AppKit

/// Where the reader writes to a session, under its transcript: a growing
/// text field and one button — *Send*, or *Stop* while a turn runs. Return
/// sends, Shift-Return breaks the line. Reports through its delegate only;
/// what sending does is the tab's.
///
/// It looks like the transcript it sits under: system colours, a 14 pt body,
/// the transcript's 720 pt column centred, a hairline on top. A message that
/// could not be sent is said under the field, in red, with the words put
/// back.
@MainActor
final class ComposerView: NSView {
    weak var delegate: ComposerViewDelegate?

    /// The transcript's column; the field never runs wider.
    private static let maxWidth: CGFloat = 720
    private static let gutter: CGFloat = 16
    private static let font = NSFont.systemFont(ofSize: 14)
    private static let textInset = NSSize(width: 10, height: 7)
    /// One line of text in the field, and how far it grows before it scrolls.
    private static let minFieldHeight: CGFloat = 32
    private static let maxFieldHeight: CGFloat = 160

    private var isResponding = false

    private lazy var hairline: HairlineView = {
        let view = HairlineView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private lazy var textView: PromptTextView = {
        let view = PromptTextView(frame: .zero)
        view.placeholder = String(localized: "Message Claude")
        view.font = Self.font
        view.textColor = .labelColor
        view.drawsBackground = false
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.textContainerInset = Self.textInset
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.setAccessibilityLabel(String(localized: "Message Claude"))
        view.delegate = self
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

    private lazy var field: FieldFrameView = {
        let view = FieldFrameView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private lazy var sendButton: PillButton = {
        let button = PillButton(title: String(localized: "Send"), isPrimary: true)
        button.target = self
        button.action = #selector(send)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private lazy var stopButton: PillButton = {
        let button = PillButton(title: String(localized: "Stop"))
        button.target = self
        button.action = #selector(stop)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        return button
    }()

    private lazy var errorLabel: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .systemRed
        label.isSelectable = true
        label.isHidden = true
        // A long message wraps; it never sets how narrow the tab can be.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var fieldHeight = scrollView.heightAnchor.constraint(equalToConstant: Self.minFieldHeight)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureHierarchy()
        configureConstraints()
        updateButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func configureHierarchy() {
        addSubview(hairline)
        addSubview(field)
        field.addSubview(scrollView)
        addSubview(sendButton)
        addSubview(stopButton)
        addSubview(errorLabel)
    }

    private func configureConstraints() {
        // The column: as wide as 720 allows, centred, a gutter from the edges.
        let guide = NSLayoutGuide()
        addLayoutGuide(guide)
        let fill = guide.widthAnchor.constraint(equalToConstant: Self.maxWidth)
        // Below 500: a window sizes itself to what its constraints ask above
        // that, and the column's width is a wish, not a minimum.
        fill.priority = NSLayoutConstraint.Priority(499)
        NSLayoutConstraint.activate([
            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 0.5),

            guide.centerXAnchor.constraint(equalTo: centerXAnchor),
            guide.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxWidth),
            guide.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Self.gutter),
            guide.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.gutter),
            fill,

            field.topAnchor.constraint(equalTo: hairline.bottomAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: field.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: field.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            fieldHeight,

            sendButton.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 8),
            sendButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            sendButton.centerYAnchor.constraint(equalTo: field.bottomAnchor, constant: -Self.minFieldHeight / 2),
            stopButton.leadingAnchor.constraint(equalTo: sendButton.leadingAnchor),
            stopButton.trailingAnchor.constraint(equalTo: sendButton.trailingAnchor),
            stopButton.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
            sendButton.widthAnchor.constraint(greaterThanOrEqualTo: stopButton.widthAnchor),
            stopButton.widthAnchor.constraint(greaterThanOrEqualTo: sendButton.widthAnchor),

            errorLabel.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 6),
            errorLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 4),
            errorLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
        ])
        // Under the field: the error when there is one, else the margin.
        bottomWithoutError.isActive = true
    }

    /// The bottom margin under the field, or under the error when there is one.
    private lazy var bottomWithoutError = field.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
    private lazy var bottomWithError = errorLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)

    // MARK: - Showing

    /// Shows *Stop* while `isResponding`, *Send* otherwise. Idempotent.
    func configure(isResponding: Bool) {
        guard isResponding != self.isResponding else { return }
        self.isResponding = isResponding
        updateButtons()
    }

    /// The field's words.
    var text: String {
        get { textView.string }
        set {
            textView.string = newValue
            contentDidChange()
        }
    }

    /// Gives the field the focus: a new session opens ready to type.
    func focus() {
        window?.makeFirstResponder(textView)
    }

    /// Says that `text` could not be sent, under the field, and puts it back
    /// unless the reader has begun something else.
    func showFailure(_ message: String, of text: String) {
        if textView.string.isEmpty {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            contentDidChange()
        }
        errorLabel.stringValue = message
        setErrorVisible(true)
    }

    private func updateButtons() {
        sendButton.isHidden = isResponding
        stopButton.isHidden = !isResponding
        sendButton.isEnabled = canSend
    }

    private var canSend: Bool {
        !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func setErrorVisible(_ visible: Bool) {
        guard errorLabel.isHidden == visible else { return }
        errorLabel.isHidden = !visible
        bottomWithoutError.isActive = !visible
        bottomWithError.isActive = visible
    }

    // MARK: - Sizing

    /// The field is as tall as its text, from one line up to the cap.
    private var wantedFieldHeight: CGFloat {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else {
            return Self.minFieldHeight
        }
        layoutManager.ensureLayout(for: container)
        let text = ceil(layoutManager.usedRect(for: container).height) + 2 * Self.textInset.height
        return min(max(text, Self.minFieldHeight), Self.maxFieldHeight)
    }

    override func layout() {
        super.layout()
        // A change of width rewraps the text; follow it.
        let wanted = wantedFieldHeight
        if abs(fieldHeight.constant - wanted) > 0.5 {
            fieldHeight.constant = wanted
            super.layout()
        }
    }

    // MARK: - Actions

    @objc private func send() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        textView.string = ""
        contentDidChange()
        setErrorVisible(false)
        delegate?.composerView(self, didSubmit: text)
    }

    @objc private func stop() {
        delegate?.composerViewDidRequestStop(self)
    }

    private func contentDidChange() {
        textView.needsDisplay = true
        sendButton.isEnabled = canSend
        fieldHeight.constant = wantedFieldHeight
        if !errorLabel.isHidden { setErrorVisible(false) }
    }
}

extension ComposerView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        contentDidChange()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            textView.insertNewlineIgnoringFieldEditor(nil)
        } else {
            send()
        }
        return true
    }
}

/// A text view that says what it is for while it is empty.
private final class PromptTextView: NSTextView {
    var placeholder = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        let origin = NSPoint(
            x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
        (placeholder as NSString).draw(
            at: origin,
            withAttributes: [.font: font ?? .systemFont(ofSize: 14), .foregroundColor: NSColor.placeholderTextColor])
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }
}

/// The field's rounded frame.
private final class FieldFrameView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 0.5
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

/// The line between the transcript and the composer.
private final class HairlineView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
    }
}
