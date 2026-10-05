import AppKit
import DisplayModels

/// The composer's card (design 08 *The composer*): an optional failure section
/// on top, the growing field, the accessory row — Model / Effort / Mode
/// pull-downs, the status slot, the context ring, the action buttons — and,
/// under the card, the one red line of an error.
///
/// It draws a `ComposerPresentation` and reports intents to its delegate; the
/// field's words are the only state it keeps. The card fills the width it is
/// given — where it stands decides that (the New view's column, a session's
/// 720), and moves it there (the glide animates that width) — and asks only
/// to be no narrower than its narrowest tier. Nothing in it hugs the card
/// narrower: the rows stretch, their spacer and labels taking the room. The
/// card is the window's background, a hairline and a soft shadow, its
/// continuous corners concentric with the action button: the button's
/// half-height and the 8 pt round it. It draws no focus: the caret is the
/// focus, as in a text view.
///
/// Words are never cut: the buttons keep as many of their words as their line
/// holds — the provider's name goes first, then Effort's and Mode's names
/// (glyphs and tooltips remain) — and when even glyphs leave no room for the
/// status, it takes a line of its own under the buttons, which then keep the
/// words their line holds. The line is measured, not matched against set
/// widths.
@MainActor
final class ComposerView: NSView {
    /// The three pull-downs.
    typealias Control = ComposerMenu.Control

    weak var delegate: ComposerViewDelegate?

    // MARK: Subviews

    /// Its corners concentric with the action button, which sits
    /// `actionInset` in from the card's corner.
    private lazy var surface = CardSurfaceView(
        radius: sendButton.intrinsicContentSize.height / 2 + Self.actionInset)
    private let failureView = ComposerFailureView()
    private let field = ComposerFieldView()
    private let modelButton = MenuButton()
    private let effortButton = MenuButton()
    private let modeButton = MenuButton()
    /// Never shown: a chip at another tier, measured without re-titling the
    /// buttons on screen.
    private let measuringButton = MenuButton()
    private let spacer = NSView()
    private let statusView = ComposerStatusView()
    private let ringView = ContextRingButton()
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
    private var tier = Tier.full

    /// How much of their words the buttons keep as the card narrows.
    private enum Tier: Int, Comparable, CaseIterable {
        case full
        /// The provider's name is gone.
        case withoutDetail
        /// Effort's and Mode's names are gone too; their glyphs remain.
        case glyphsOnly

        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }
    private var isNarrow = false

    private lazy var bottomWithoutError = surface.bottomAnchor.constraint(equalTo: bottomAnchor)
    private lazy var bottomWithError = errorLabel.bottomAnchor.constraint(equalTo: bottomAnchor)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureHierarchy()
        configureConstraints()
        configureActions()
    }

    /// The action buttons' distance from the card's trailing and bottom edges.
    private static let actionInset: CGFloat = 8

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func configureHierarchy() {
        field.delegate = self
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        controlsRow.orientation = .horizontal
        controlsRow.alignment = .centerY
        controlsRow.spacing = 0
        // The row is the card's width: its spacer takes the room.
        controlsRow.setHuggingPriority(.stretches, for: .horizontal)
        controlsRow.setViews(
            [modelButton, effortButton, modeButton, spacer, statusView, ringView, stopButton, sendButton],
            in: .leading)
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
        // The card's width, its words wrapping in it.
        errorLabel.setContentHuggingPriority(.stretches, for: .horizontal)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 0
        contentStack.setHuggingPriority(.stretches, for: .horizontal)
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

    /// The narrowest the card is: its buttons at their last tier, the status
    /// on its own line — set by `layout` from what they hold. Required, so a
    /// tab, a split and the window are never narrower than the card can be.
    private lazy var minimumWidth = surface.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)

    private func configureConstraints() {
        // The card is the view's width, no narrower than its last tier.
        minimumWidth.isActive = true
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
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
            controlsRow.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -Self.actionInset),
            controlsRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            statusLine.topAnchor.constraint(equalTo: controlsRow.bottomAnchor),
            statusLine.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 8),
            statusLine.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -8),
            statusLine.heightAnchor.constraint(equalToConstant: Self.statusLineHeight),
        ])
        bodyBottomPlain.isActive = true
    }

    /// The card's bottom padding, under the chips or under the status line.
    private lazy var bodyBottomPlain = controlsRow.bottomAnchor.constraint(
        equalTo: body.bottomAnchor, constant: -Self.actionInset)
    private lazy var bodyBottomWithStatus = statusLine.bottomAnchor.constraint(
        equalTo: body.bottomAnchor, constant: -Self.actionInset)

    private func configureActions() {
        for (control, button) in [(Control.model, modelButton), (.effort, effortButton), (.mode, modeButton)] {
            // The words keep their width over everything but the window's: the
            // card drops them by tier as it narrows (`layout`), so they are
            // never cut — and never what widens the window.
            button.setContentCompressionResistancePriority(.dragThatCannotResizeWindow, for: .horizontal)
            button.target = self
            button.action = #selector(menuButtonPressed(_:))
            button.tag = control.tag
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
        statusView.waitingButton.target = self
        statusView.waitingButton.action = #selector(showWaitingRequest)
        ringView.target = self
        ringView.action = #selector(showContextUsage)
        sendButton.setAccessibilityLabel(String(localized: "Send", bundle: .module))
        stopButton.setAccessibilityLabel(String(localized: "Stop", bundle: .module))
    }

    // MARK: - Showing

    /// Shows `model`. Idempotent: the field's words are kept.
    func configure(with model: ComposerPresentation) {
        self.model = model
        field.placeholder = model.placeholder
        showButtons()
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

    /// Opens `popover` from `control`'s button, over it when `above`.
    func showMenu(of control: Control, in popover: MenuPopover, above: Bool) {
        let button =
            switch control {
            case .model: modelButton
            case .effort: effortButton
            case .mode: modeButton
            }
        popover.show(from: button, above: above)
    }

    // MARK: - The buttons

    private var chips: [(chip: ComposerPresentation.Chip, button: MenuButton)] {
        guard let model else { return [] }
        return [(model.model, modelButton), (model.effort, effortButton), (model.mode, modeButton)]
    }

    private func showButtons() {
        for (chip, button) in chips { show(chip, on: button, at: tier) }
    }

    /// `chip` on `button`, as much as `tier` keeps: its glyph, title and
    /// detail, in secondary ink, red for Bypass, tertiary while disabled; the
    /// detail and the trailing clock tertiary; no chevron while disabled.
    private func show(_ chip: ComposerPresentation.Chip, on button: MenuButton, at tier: Tier) {
        let ink: NSColor = !chip.isEnabled ? .tertiaryLabelColor : chip.isDanger ? .failureText : .secondaryLabelColor
        button.show(
            chip.titleIsDroppable && tier >= .glyphsOnly ? "" : chip.title, font: .systemFont(ofSize: 12), ink: ink,
            glyph: chip.glyph.flatMap(ComposerGlyph.chipImage),
            detail: tier < .withoutDetail ? chip.detail : nil,
            trailing: chip.trailingGlyph.flatMap(ComposerGlyph.inlineImage), hasChevron: chip.isEnabled)
        button.isEnabled = chip.isEnabled
        button.toolTip = chip.toolTip
        button.setAccessibilityLabel(chip.toolTip ?? chip.title)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        // The room the card is given, not the width its contents ask for — a
        // question constraints can't ask, so the line is measured at each tier.
        let width = bounds.width
        guard width > 0, model != nil else { return }
        // The line as it is, less the status; the status's own width.
        let status = statusView.isEmpty ? 0 : statusView.fittingSize.width + 4
        let line = controlsRow.fittingSize.width + 16 - (statusView.superview === controlsRow ? status : 0)
        let widths = Tier.allCases.map { (tier: $0, width: line + growth(of: $0)) }
        if let narrowest = widths.last?.width, abs(minimumWidth.constant - narrowest) > 0.5 {
            minimumWidth.constant = narrowest
        }
        // The fullest words that fit beside the status; when even the glyphs
        // don't, the status takes its own line and the words fit without it.
        let nextTier: Tier
        let nextNarrow: Bool
        if let fits = widths.first(where: { $0.width + status <= width }) {
            (nextTier, nextNarrow) = (fits.tier, false)
        } else {
            nextTier = widths.first { $0.width <= width }?.tier ?? .glyphsOnly
            nextNarrow = true
        }
        let tierChanged = nextTier != tier
        if tierChanged {
            tier = nextTier
            showButtons()
        }
        let narrowChanged = nextNarrow != isNarrow
        if narrowChanged {
            isNarrow = nextNarrow
            updateStatusPlacement()
        }
        guard tierChanged || narrowChanged else { return }
        super.layout()
    }

    /// How much wider the buttons are at `tier` than as they are shown.
    private func growth(of tier: Tier) -> CGFloat {
        guard tier != self.tier else { return 0 }
        return chips.reduce(0) { growth, shown in
            show(shown.chip, on: measuringButton, at: tier)
            return growth + measuringButton.intrinsicContentSize.width - shown.button.intrinsicContentSize.width
        }
    }

    override func mouseDown(with event: NSEvent) {
        // The card is one big target for the field.
        field.focus()
    }

    // MARK: - Actions

    @objc private func menuButtonPressed(_ sender: NSButton) {
        guard let control = Control(tag: sender.tag) else { return }
        delegate?.composerView(self, didPress: control)
    }

    @objc private func stop() {
        delegate?.composerViewDidRequestStop(self)
    }

    @objc private func showWaitingRequest() {
        delegate?.composerViewDidRequestWaitingRequest(self)
    }

    @objc private func showContextUsage() {
        delegate?.composerViewDidRequestContextUsage(self)
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
/// a 1-pt contact shadow and a soft one. The content is clipped to the
/// corners (the failure section's wash runs to the edge); the ring and
/// shadows are not.
private final class CardSurfaceView: NSView {
    /// Where the content goes; clips to the card's shape.
    let clip = NSView()

    /// The corners' radius.
    private let radius: CGFloat

    /// The card's shape under its content, casting the soft shadow. The
    /// view's own layer has no corner radius — AppKit would mask it, and the
    /// ring and shadows are outside its bounds.
    private let body = CALayer()
    private let contact = CALayer()
    private let ring = CALayer()

    private let ringWidth: CGFloat = 0.5

    init(radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = false
        // 0 6 20: a 20-pt blur is a 10-pt shadow radius.
        body.shadowOffset = CGSize(width: 0, height: -6)
        body.shadowRadius = 10
        contact.shadowOffset = CGSize(width: 0, height: -1)
        contact.shadowRadius = 1
        for edge in [contact, body, ring] {
            edge.cornerCurve = .continuous
            layer?.addSublayer(edge)
        }
        clip.wantsLayer = true
        clip.layer?.cornerRadius = radius
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
            body.backgroundColor = NSColor.windowBackgroundColor.cgColor
            clip.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            body.shadowColor = NSColor.black.cgColor
            body.shadowOpacity = 0.06
            contact.shadowColor = NSColor.black.cgColor
            contact.shadowOpacity = 0.04
            ring.borderColor = NSColor.separatorColor.cgColor
        }
        placeEdges()
    }

    override func layout() {
        super.layout()
        placeEdges()
    }

    /// The ring sits outside the edge, its corners grown by its width.
    private func placeEdges() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body.frame = bounds
        body.cornerRadius = radius
        ring.borderWidth = ringWidth
        ring.frame = bounds.insetBy(dx: -ringWidth, dy: -ringWidth)
        ring.cornerRadius = radius + ringWidth
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
/// — AppKit's accessory-bar button, whose press scrolls to the request.
private final class ComposerStatusView: NSView {
    let waitingButton = NSButton(title: "", target: nil, action: nil)

    private let label = NSTextField(labelWithString: "")
    private let tile = TileView()
    private let tileHost = NSView()

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
        label.textColor = .tertiaryLabelColor
        waitingButton.bezelStyle = .accessoryBar
        waitingButton.showsBorderOnlyWhileMouseInside = true
        waitingButton.setContentCompressionResistancePriority(.dragThatCannotResizeWindow, for: .horizontal)
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
        stack.setViews([tileHost, label, waitingButton], in: .leading)
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
            label.isHidden = false
            waitingButton.isHidden = true
        case .waitingForYou(let words):
            waitingButton.attributedTitle = NSAttributedString(
                string: words,
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.sidebarCoral])
            label.isHidden = true
            waitingButton.isHidden = false
        }
        tileHost.isHidden = !isBusy
    }
}
