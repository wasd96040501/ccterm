import AppKit

// MARK: - AppKit backing view

/// Self-drawn diff body. Same draw recipe as `BlockCellView` for diff
/// bodies (backplate → selection band → glyphs) but trimmed to a single
/// block: no row indirection, no controller, no fold / search overlay.
final class DiffNSView: NSView, NSUserInterfaceValidations {
    private var diff: DiffBlock?
    private var lineMap: [String: [SyntaxToken]]?
    private var showsLangBadge: Bool = true
    private var showsCopyIcon: Bool = true

    private var cachedLayout: DiffLayout?
    private var cachedWidth: CGFloat = -1

    private var anchorChar: Int?
    private var cursorChar: Int?

    /// Stable id for the in-card copy button — keyed per-view so the
    /// hover / copied flags survive width-driven layout cache flushes
    /// and don't collide across multiple `DiffNSView` instances on
    /// screen at once. Matches the `CopyChrome.id` the underlying
    /// `DiffLayout` carries.
    private let copyButtonId = UUID()
    private var copyButtonHovered = false
    private var copyButtonCopied = false
    private var copyButtonCopyStamp: Date?
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Cache the CG-drawn bitmap; only redraw on explicit needsDisplay.
        // Same posture as transcript cells — selection drag and key-window
        // flips become bitmap composites, not glyph re-typeset passes.
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - SwiftUI-driven update

    func update(
        diff: DiffBlock,
        lineMap: [String: [SyntaxToken]]?,
        showsLangBadge: Bool,
        showsCopyIcon: Bool
    ) {
        let diffChanged = self.diff != diff
        let lineMapChanged = !sameLineMap(self.lineMap, lineMap)
        let chromeChanged =
            self.showsLangBadge != showsLangBadge
            || self.showsCopyIcon != showsCopyIcon
        guard diffChanged || lineMapChanged || chromeChanged else { return }
        if diffChanged {
            anchorChar = nil
            cursorChar = nil
        }
        self.diff = diff
        self.lineMap = lineMap
        self.showsLangBadge = showsLangBadge
        self.showsCopyIcon = showsCopyIcon
        invalidateLayoutCache()
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    /// Cheap check covering the only realistic transitions: `nil ↔ some`
    /// (highlight arrives or diff resets) and `some(a) → some(b)` where
    /// `a` and `b` may carry different unique-line counts. Same-count
    /// non-identical maps are not produced by the current pipeline (the
    /// only producer is `runHighlight`, which writes once per diff).
    private func sameLineMap(
        _ a: [String: [SyntaxToken]]?,
        _ b: [String: [SyntaxToken]]?
    ) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (.some(let l), .some(let r)): return l.count == r.count
        default: return false
        }
    }

    // MARK: - Layout

    private func invalidateLayoutCache() {
        cachedLayout = nil
        cachedWidth = -1
    }

    private func layout(at width: CGFloat) -> DiffLayout? {
        guard let diff else { return nil }
        if let cachedLayout, cachedWidth == width { return cachedLayout }
        let made = DiffLayout.make(
            diff: diff,
            lineMap: lineMap,
            // Standalone view: id is per-instance, payload is the
            // post-edit content (same convention as the transcript's
            // FileEdit copy button).
            copyButtonId: copyButtonId,
            copyText: diff.newString,
            originX: 0,
            originY: 0,
            maxWidth: max(0, width),
            showsLangBadge: showsLangBadge,
            showsCopyIcon: showsCopyIcon)
        cachedLayout = made
        cachedWidth = width
        return made
    }

    func height(at width: CGFloat) -> CGFloat {
        layout(at: width)?.totalHeight ?? 0
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.size.width
        super.setFrameSize(newSize)
        // Don't invalidate explicitly — `layout(at:)` keys on width and
        // rebuilds on miss. `sizeThatFits` typically primes the cache for
        // the same width SwiftUI then assigns here, so we usually hit.
        if widthChanged { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        if let cachedLayout, cachedWidth == bounds.width {
            return NSSize(
                width: NSView.noIntrinsicMetric,
                height: cachedLayout.totalHeight)
        }
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: NSView.noIntrinsicMetric)
    }

    // MARK: - Draw

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
            let layout = layout(at: bounds.width)
        else { return }
        let origin = CGPoint.zero
        layout.drawBackplate(in: ctx, origin: origin)
        if let lo = selectionLo, let hi = selectionHi, lo < hi {
            let color: NSColor =
                (window?.isKeyWindow == true)
                ? .selectedTextBackgroundColor
                : .unemphasizedSelectedTextBackgroundColor
            ctx.setFillColor(color.cgColor)
            for rect in layout.rects(loChar: lo, hiChar: hi) {
                ctx.fill(rect.offsetBy(dx: origin.x, dy: origin.y).integral)
            }
        }
        layout.draw(in: ctx, origin: origin)
        layout.drawHeaderChrome(
            in: ctx, origin: origin,
            hoveredCopyId: copyButtonHovered ? copyButtonId : nil,
            flashingCopyIds: copyButtonCopied ? [copyButtonId] : [])
    }

    // MARK: - Selection state

    private var selectionLo: Int? {
        guard let a = anchorChar, let c = cursorChar, a != c else { return nil }
        return min(a, c)
    }

    private var selectionHi: Int? {
        guard let a = anchorChar, let c = cursorChar, a != c else { return nil }
        return max(a, c)
    }

    private var hasSelection: Bool { selectionLo != nil }

    // MARK: - Mouse input

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let layout = layout(at: bounds.width) else { return }
        let local = convert(event.locationInWindow, from: nil)
        if let copy = layout.copy, copy.hitRect.contains(local) {
            handleCopyButtonClick(text: copy.text)
            return
        }
        switch event.clickCount {
        case 1:
            let char = layout.hitTest(point: local)
            anchorChar = char
            cursorChar = char
        case 2:
            let char = layout.hitTest(point: local)
            if let word = layout.wordBoundary(at: char) {
                anchorChar = word.location
                cursorChar = word.location + word.length
            } else {
                anchorChar = char
                cursorChar = char
            }
        default:
            anchorChar = 0
            cursorChar = layout.contentLength
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let layout = layout(at: bounds.width), anchorChar != nil
        else { return }
        let local = convert(event.locationInWindow, from: nil)
        cursorChar = layout.hitTest(point: local)
        autoscroll(with: event)
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .activeInKeyWindow,
                .inVisibleRect,
            ],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateCopyHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        updateCopyHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        if copyButtonHovered {
            copyButtonHovered = false
            needsDisplay = true
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if let copy = layout(at: bounds.width)?.copy {
            addCursorRect(copy.hitRect, cursor: .pointingHand)
        }
    }

    private func updateCopyHover(at local: NSPoint) {
        guard let copy = layout(at: bounds.width)?.copy else {
            if copyButtonHovered {
                copyButtonHovered = false
                needsDisplay = true
            }
            return
        }
        let nowHovered = copy.hitRect.contains(local)
        if nowHovered != copyButtonHovered {
            copyButtonHovered = nowHovered
            needsDisplay = true
        }
    }

    private func handleCopyButtonClick(text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        let stamp = Date()
        copyButtonCopyStamp = stamp
        copyButtonCopied = true
        needsDisplay = true
        let delayNs = UInt64(
            BlockStyle.gutterCopiedFeedbackSeconds * 1_000_000_000)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNs)
            guard let self, self.copyButtonCopyStamp == stamp else { return }
            self.copyButtonCopied = false
            self.copyButtonCopyStamp = nil
            self.needsDisplay = true
        }
    }

    // MARK: - Standard responder actions

    @objc func copy(_ sender: Any?) {
        guard let layout = cachedLayout,
            let lo = selectionLo, let hi = selectionHi
        else { return }
        let text = layout.string(loChar: lo, hiChar: hi)
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        guard let layout = layout(at: bounds.width),
            layout.contentLength > 0
        else { return }
        anchorChar = 0
        cursorChar = layout.contentLength
        needsDisplay = true
    }

    func validateUserInterfaceItem(
        _ item: NSValidatedUserInterfaceItem
    ) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            return hasSelection
        case #selector(selectAll(_:)):
            return (cachedLayout?.contentLength ?? 0) > 0
        default:
            return true
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard hasSelection else { return nil }
        let menu = NSMenu()
        menu.addItem(
            withTitle: String(localized: "Copy"),
            action: #selector(copy(_:)),
            keyEquivalent: "")
        return menu
    }

    // MARK: - Key window state

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self)
        guard let window else { return }
        center.addObserver(
            self, selector: #selector(keyWindowDidChange),
            name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(
            self, selector: #selector(keyWindowDidChange),
            name: NSWindow.didResignKeyNotification, object: window)
    }

    @objc private func keyWindowDidChange() {
        if hasSelection { needsDisplay = true }
    }
}
