import AppKit
import DisplayModels

/// The composer's card (design 08 *The composer*): an optional failure section
/// on top, the growing field, the accessory row — Model / Effort / Mode
/// pull-downs, the status slot, the context ring, the action buttons — and,
/// under the card, the one red line of an error.
///
/// It draws a `ComposerPresentation` and reports intents to its delegate; the
/// field's words are the only state it keeps. The card is 720 pt at most,
/// centred, the card radius with continuous corners, the window's background,
/// a hairline and a soft shadow; focus adds a 1-pt accent ring at 45 % and a
/// 4-pt halo at 12 %.
///
/// Words are never cut: when the card narrows the chips drop the provider's
/// name, then Effort's and Mode's names (glyphs and tooltips remain), and
/// below 380 pt the status takes a line of its own under the chips.
@MainActor
final class ComposerView: NSView {
    /// The three pull-downs.
    typealias Control = ComposerMenu.Control

    weak var delegate: ComposerViewDelegate?

    static let maxWidth: CGFloat = 720
    /// The card's width below which the status takes its own line.
    static let narrowWidth: CGFloat = 380

    // MARK: Subviews

    private let surface = CardSurfaceView()
    private let failureView = ComposerFailureView()
    private let field = ComposerFieldView()
    private let modelChip = ComposerChipButton()
    private let effortChip = ComposerChipButton()
    private let modeChip = ComposerChipButton()
    private let spacer = NSView()
    private let statusView = ComposerStatusView()
    private let ringView = ContextRingView()
    private let stopButton = ComposerActionButton(kind: .stop)
    private let sendButton = ComposerActionButton(kind: .send)
    private let controlsRow = NSStackView()
    /// The status's own line, narrow: the sheet's 11 × 1.45 line straight
    /// under the controls (its narrow `margin: 4px 8px 0` loses to the base
    /// `.lv-status { margin: 0 8px }` that follows it in the stylesheet).
    private let statusLine = NSView()
    private static let statusLineHeight: CGFloat = 11 * 1.45
    private let contentStack = NSStackView()
    private let body = NSView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")

    private var model: ComposerPresentation?
    private var tier = ComposerChipButton.Tier.full
    private var isNarrow = false

    private lazy var bottomWithoutError = surface.bottomAnchor.constraint(equalTo: bottomAnchor)
    private lazy var bottomWithError = errorLabel.bottomAnchor.constraint(equalTo: bottomAnchor)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureHierarchy()
        configureConstraints()
        configureActions()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func configureHierarchy() {
        field.delegate = self
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        controlsRow.orientation = .horizontal
        controlsRow.alignment = .centerY
        controlsRow.spacing = 0
        controlsRow.setViews(
            [modelChip, effortChip, modeChip, spacer, statusView, ringView, stopButton, sendButton], in: .leading)
        // preview-live.css: the status keeps 8 on either side (its own insets),
        // the ring 8 after it, and every action button 4 before it.
        controlsRow.setCustomSpacing(4, after: spacer)
        controlsRow.setCustomSpacing(4, after: statusView)
        controlsRow.setCustomSpacing(12, after: ringView)
        controlsRow.setCustomSpacing(4, after: stopButton)

        statusLine.isHidden = true

        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .failureText
        errorLabel.isSelectable = true
        errorLabel.isHidden = true
        errorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 0
        contentStack.setViews([failureView, body], in: .leading)
        failureView.isHidden = true

        for view in [field, controlsRow, statusLine] {
            view.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(view)
        }
        for view in [surface, errorLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for view in [contentStack, failureView, body] { view.translatesAutoresizingMaskIntoConstraints = false }
        surface.clip.addSubview(contentStack)
    }

    private func configureConstraints() {
        // The column: as wide as 720 allows, centred — a wish, never a size
        // for the window.
        let fill = surface.widthAnchor.constraint(equalToConstant: Self.maxWidth)
        fill.priority = .wishUnderWindowSize
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.centerXAnchor.constraint(equalTo: centerXAnchor),
            surface.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxWidth),
            surface.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            surface.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            fill,
            errorLabel.topAnchor.constraint(equalTo: surface.bottomAnchor, constant: 8),
            errorLabel.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 16),
            errorLabel.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -16),
            bottomWithoutError,

            contentStack.topAnchor.constraint(equalTo: surface.clip.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: surface.clip.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: surface.clip.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: surface.clip.bottomAnchor),
            failureView.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            body.widthAnchor.constraint(equalTo: contentStack.widthAnchor),

            field.topAnchor.constraint(equalTo: body.topAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -16),
            controlsRow.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            controlsRow.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 8),
            controlsRow.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -8),
            controlsRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            statusLine.topAnchor.constraint(equalTo: controlsRow.bottomAnchor),
            statusLine.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 8),
            statusLine.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -8),
            statusLine.heightAnchor.constraint(equalToConstant: Self.statusLineHeight),
        ])
        bodyBottomPlain.isActive = true
    }

    /// The card's bottom padding, under the chips or under the status line.
    private lazy var bodyBottomPlain = controlsRow.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -8)
    private lazy var bodyBottomWithStatus = statusLine.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -8)

    private func configureActions() {
        for (control, chip) in [(Control.model, modelChip), (.effort, effortChip), (.mode, modeChip)] {
            chip.target = self
            chip.action = #selector(chipPressed(_:))
            chip.tag = control.tag
        }
        stopButton.target = self
        stopButton.action = #selector(stop)
        sendButton.target = self
        sendButton.action = #selector(send)
        failureView.onRestart = { [weak self] in
            guard let self else { return }
            self.delegate?.composerViewDidRequestRestart(self)
        }
        failureView.onShowLog = { [weak self] in
            guard let self else { return }
            self.delegate?.composerViewDidRequestLog(self)
        }
        statusView.onPress = { [weak self] in
            guard let self else { return }
            self.delegate?.composerViewDidRequestWaitingRequest(self)
        }
        ringView.onPress = { [weak self] in
            guard let self else { return }
            self.delegate?.composerViewDidRequestContextUsage(self)
        }
        sendButton.setAccessibilityLabel(String(localized: "Send", bundle: .module))
        stopButton.setAccessibilityLabel(String(localized: "Stop", bundle: .module))
    }

    // MARK: - Showing

    /// Shows `model`. Idempotent: the field's words are kept.
    func configure(with model: ComposerPresentation) {
        self.model = model
        field.placeholder = model.placeholder
        modelChip.configure(with: model.model)
        effortChip.configure(with: model.effort)
        modeChip.configure(with: model.mode)
        statusView.configure(status: model.status, isBusy: model.statusIsBusy)
        if let fraction = model.contextRing, let text = model.contextRingText {
            ringView.configure(fraction: fraction, text: text, toolTip: model.contextRingToolTip)
            ringView.isHidden = false
        } else {
            ringView.isHidden = true
        }
        stopButton.toolTip = model.stopToolTip
        sendButton.toolTip = model.sendToolTip
        if let failure = model.failure {
            failureView.configure(with: failure)
            failureView.isHidden = false
        } else {
            failureView.isHidden = true
        }
        errorLabel.stringValue = model.error ?? ""
        let hasError = model.error != nil
        errorLabel.isHidden = !hasError
        bottomWithoutError.isActive = !hasError
        bottomWithError.isActive = hasError
        updateActions()
        updateStatusPlacement()
        needsLayout = true
    }

    private func updateActions() {
        let isStop = model?.action == .stop
        stopButton.isHidden = !isStop
        // Working with text in the field shows both, stop to the left.
        sendButton.isHidden = isStop && !field.hasContent
        sendButton.isEnabled = field.hasContent
    }

    /// The status sits before the buttons; narrow, it takes a line under them.
    private func updateStatusPlacement() {
        let wantsOwnLine = isNarrow && !statusView.isEmpty
        if wantsOwnLine {
            if statusView.superview !== statusLine {
                controlsRow.removeArrangedSubview(statusView)
                statusView.removeFromSuperview()
                statusLine.addSubview(statusView)
                NSLayoutConstraint.activate([
                    statusView.leadingAnchor.constraint(equalTo: statusLine.leadingAnchor),
                    statusView.trailingAnchor.constraint(lessThanOrEqualTo: statusLine.trailingAnchor),
                    statusView.centerYAnchor.constraint(equalTo: statusLine.centerYAnchor),
                ])
            }
        } else if statusView.superview !== controlsRow {
            statusView.removeFromSuperview()
            controlsRow.insertArrangedSubview(
                statusView, at: controlsRow.arrangedSubviews.firstIndex(of: ringView) ?? 0)
            controlsRow.setCustomSpacing(4, after: statusView)
        }
        statusLine.isHidden = !wantsOwnLine
        bodyBottomPlain.isActive = !wantsOwnLine
        bodyBottomWithStatus.isActive = wantsOwnLine
    }

    // MARK: - Words

    /// Everything the field holds, a completed command as its `/name`.
    var text: String { field.fullText }

    /// Sets the field's words; a leading `/name` that `isCommand` knows becomes
    /// the command token.
    func setText(_ text: String) {
        let names = Set((model?.commands ?? []).map(\.name))
        field.setText(text) { names.contains($0) }
    }

    var slashQuery: String? { field.slashQuery }

    /// Whether the field's words are dimmed; the card, chips and buttons are not.
    var isFieldDimmed: Bool {
        get { field.isDimmed }
        set { field.isDimmed = newValue }
    }

    func complete(command name: String) {
        field.complete(command: name)
    }

    func focus() {
        field.focus()
    }

    /// The card, in this view's coordinates.
    var cardFrame: NSRect { convert(surface.bounds, from: surface) }

    /// Opens `menu` with `content` from `control`'s chip, which shows itself open.
    func showMenu(of control: Control, content: MenuContent, in menu: MenuPanel, preferring side: MenuPopup.Side) {
        let chip = chip(for: control)
        chip.isOpen = true
        menu.show(content, from: chip, preferring: side)
    }

    /// Shows `control`'s chip as open or closed.
    func setMenuOpen(_ isOpen: Bool, for control: Control) {
        chip(for: control).isOpen = isOpen
    }

    /// Shows `control`'s chip open and gives the view its menu points at,
    /// for a menu drawn still.
    func showMenuStill(of control: Control) -> NSView {
        let chip = chip(for: control)
        chip.isOpen = true
        return chip
    }

    private func chip(for control: Control) -> ComposerChipButton {
        switch control {
        case .model: modelChip
        case .effort: effortChip
        case .mode: modeChip
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        // Narrowing is a question of the card's own width, which constraints can't ask.
        // (The room the card is given, not the width its contents ask for.)
        let width = min(bounds.width, Self.maxWidth)
        let nextTier: ComposerChipButton.Tier = width > 600 ? .full : width > 500 ? .withoutDetail : .glyphsOnly
        let tierChanged = nextTier != tier
        if tierChanged {
            tier = nextTier
            for chip in [modelChip, effortChip, modeChip] { chip.tier = nextTier }
        }
        // The status takes its own line below 380, and wherever its words
        // wouldn't fit beside the controls — never cut, never widening the card.
        let nextNarrow = width > 0 && (width < Self.narrowWidth || !statusFitsInline(at: width))
        let narrowChanged = nextNarrow != isNarrow
        if narrowChanged {
            isNarrow = nextNarrow
            updateStatusPlacement()
        }
        guard tierChanged || narrowChanged else { return }
        super.layout()
    }

    /// Whether the controls' line holds the status at `width`.
    private func statusFitsInline(at width: CGFloat) -> Bool {
        guard !statusView.isEmpty else { return true }
        var needed = controlsRow.fittingSize.width + 16
        if statusView.superview !== controlsRow { needed += statusView.fittingSize.width + 4 }
        return needed <= width
    }

    override func mouseDown(with event: NSEvent) {
        // The card is one big target for the field.
        field.focus()
    }

    // MARK: - Actions

    @objc private func chipPressed(_ sender: ComposerChipButton) {
        guard let control = Control(tag: sender.tag) else { return }
        delegate?.composerView(self, didPress: control)
    }

    @objc private func stop() {
        delegate?.composerViewDidRequestStop(self)
    }

    @objc private func send() {
        submit()
    }

    /// Sends what the field holds, if it holds anything; the field clears.
    func submit() {
        guard field.hasContent else { return }
        let words = field.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        field.setText("") { _ in false }
        delegate?.composerView(self, didSubmit: words)
    }
}

extension ComposerView.Control {
    fileprivate var tag: Int {
        switch self {
        case .model: 0
        case .effort: 1
        case .mode: 2
        }
    }

    fileprivate init?(tag: Int) {
        switch tag {
        case 0: self = .model
        case 1: self = .effort
        case 2: self = .mode
        default: return nil
        }
    }
}

extension ComposerView: ComposerFieldViewDelegate {
    func composerFieldViewDidChange(_ field: ComposerFieldView) {
        updateActions()
        delegate?.composerViewDidChangeText(self)
    }

    func composerFieldView(_ field: ComposerFieldView, didChangeFocus isFocused: Bool) {
        surface.isFocused = isFocused
    }

    func composerFieldView(_ field: ComposerFieldView, handle key: ComposerFieldView.Key) -> Bool {
        if let delegate, delegate.composerView(self, handle: key) { return true }
        switch key {
        case .send:
            submit()
            return true
        default:
            return false
        }
    }
}

// MARK: - The card's surface

/// The card: the window's background with continuous corners, and around it
/// what the design draws as box-shadows (preview-live.css `.lv-comp`) — all
/// outside the edge, so the card is its full width: a 0.5-pt separator ring,
/// a 1-pt contact shadow and a soft one; in focus, a 1-pt accent ring at 45 %
/// over a 4-pt halo at 12 %, and no contact shadow. The content is clipped to
/// the corners (the failure section's wash runs to the edge); the rings and
/// shadows are not.
private final class CardSurfaceView: NSView {
    /// Where the content goes; clips to the card's shape.
    let clip = NSView()

    var isFocused = false {
        didSet {
            guard isFocused != oldValue else { return }
            needsDisplay = true
            needsLayout = true
        }
    }

    /// The card's shape under its content, casting the soft shadow. The
    /// view's own layer has no corner radius — AppKit would mask it, and the
    /// rings and shadows are outside its bounds.
    private let body = CALayer()
    private let contact = CALayer()
    private let halo = CALayer()
    private let ring = CALayer()

    private var ringWidth: CGFloat { isFocused ? 1 : 0.5 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = false
        // 0 6 20: a 20-pt blur is a 10-pt shadow radius.
        body.shadowOffset = CGSize(width: 0, height: -6)
        body.shadowRadius = 10
        contact.shadowOffset = CGSize(width: 0, height: -1)
        contact.shadowRadius = 1
        halo.borderWidth = 4
        for edge in [contact, body, halo, ring] {
            edge.cornerCurve = .continuous
            layer?.addSublayer(edge)
        }
        clip.wantsLayer = true
        clip.layer?.cornerRadius = CornerRadius.card
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        clip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clip)
        NSLayoutConstraint.activate([
            clip.topAnchor.constraint(equalTo: topAnchor),
            clip.leadingAnchor.constraint(equalTo: leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: trailingAnchor),
            clip.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = NSColor.controlAccentColor
            body.backgroundColor = NSColor.windowBackgroundColor.cgColor
            clip.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            body.shadowColor = NSColor.black.cgColor
            body.shadowOpacity = 0.06
            contact.shadowColor = NSColor.black.cgColor
            contact.shadowOpacity = isFocused ? 0 : 0.04
            ring.borderColor = (isFocused ? accent.withAlphaComponent(0.45) : NSColor.separatorColor).cgColor
            halo.borderColor = accent.withAlphaComponent(0.12).cgColor
            halo.isHidden = !isFocused
        }
        placeEdges()
    }

    override func layout() {
        super.layout()
        placeEdges()
    }

    /// The rings sit outside the edge, their corners grown by their width.
    private func placeEdges() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let radius = CornerRadius.card
        body.frame = bounds
        body.cornerRadius = radius
        ring.borderWidth = ringWidth
        ring.frame = bounds.insetBy(dx: -ringWidth, dy: -ringWidth)
        ring.cornerRadius = radius + ringWidth
        halo.frame = bounds.insetBy(dx: -4, dy: -4)
        halo.cornerRadius = radius + 4
        contact.frame = bounds
        contact.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - The status slot

/// The status slot (design 08 *The status slot*): 11-pt tertiary words, with the
/// running arc while the CLI starts or compacts, or the coral *Waiting for you ↑*
/// whose click scrolls to the request.
private final class ComposerStatusView: NSView {
    var onPress: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let tile = TileView()
    private let tileHost = NSView()
    private var isWaitingForYou = false

    var isEmpty: Bool { isHidden }

    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byClipping
        // Its words never set the card's width — the card moves them to their
        // own line instead (`ComposerView.layout`); a resistance above the
        // window's would widen the window.
        label.setContentCompressionResistancePriority(.dragThatCannotResizeWindow, for: .horizontal)
        tileHost.translatesAutoresizingMaskIntoConstraints = false
        // The design draws the tile at three quarters (12 pt) with a −3 margin,
        // so it takes 10 pt of the line and overhangs it by 1 on each side.
        tile.tile = Tile(glyph: .tool(.other), state: .running)
        tile.frame = NSRect(x: -1, y: -1, width: 12, height: 12)
        tile.setBoundsSize(NSSize(width: 16, height: 16))
        tileHost.addSubview(tile)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.setViews([tileHost, label], in: .leading)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            tileHost.widthAnchor.constraint(equalToConstant: 10),
            tileHost.heightAnchor.constraint(equalToConstant: 10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 20),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(status: ComposerPresentation.Status?, isBusy: Bool) {
        guard let status else {
            isHidden = true
            return
        }
        isHidden = false
        switch status {
        case .note(let words):
            label.stringValue = words
            isWaitingForYou = false
        case .waitingForYou(let words):
            label.stringValue = words
            isWaitingForYou = true
        }
        tileHost.isHidden = !isBusy
        label.textColor = isWaitingForYou ? NSColor.sidebarCoral : .tertiaryLabelColor
        setAccessibilityRole(isWaitingForYou ? .button : .staticText)
        setAccessibilityLabel(label.stringValue)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isWaitingForYou && bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        if isWaitingForYou { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isWaitingForYou else { return false }
        onPress?()
        return true
    }
}
