import AppKit

/// What a reader did to an editor's tabs, reported to the group that owns them.
///
/// The bar holds no tabs of its own — it is handed `Item`s and reports indexes —
/// so every answer here is the group's to give.
@MainActor
protocol EditorTabBarDelegate: AnyObject {

    func tabBar(_ tabBar: EditorTabBar, didSelectTabAt index: Int)

    func tabBar(_ tabBar: EditorTabBar, didCloseTabAt index: Int)

    /// The menu a right-click on the tab at `index` opens, or `nil` for none.
    func tabBar(_ tabBar: EditorTabBar, menuForTabAt index: Int) -> NSMenu?

    /// The tab at `index` of `source` was dragged here and should end up at
    /// `destination` — a final position, whichever bar it came from. Answers
    /// where it actually landed, which a pinned tab's region may have moved, or
    /// `nil` if it was refused.
    func tabBar(
        _ tabBar: EditorTabBar, moveTabAt index: Int, of source: EditorTabBar,
        to destination: Int
    ) -> Int?
}

/// An editor's row of tabs: AppKit's own segmented control in its tab role — the
/// capsule track with the selected tab raised out of it that Xcode's editor
/// tabs are — plus the four things a segmented control does not do.
///
/// **The control draws everything a tab looks like.** On macOS 27
/// `NSSegmentedControl.Role.tabs` at `.large` is that capsule, in both
/// appearances and in an inactive window, so no pixel of a tab is drawn here.
/// Earlier systems get the ordinary segmented control, which is the same shape
/// without the glass. What is added sits on top of it:
///
/// - **A close button over the hovered tab**, at its leading edge where Xcode puts
///   it, and never over a pinned one.
/// - **Pinning**, which is only presentation here: a pinned tab has a pin for an
///   image and is as wide as its title, where every other tab shares what is
///   left. Which tabs are pinned, and that they come first, is the group's.
/// - **Dragging.** Within a bar a dragged tab moves as the pointer crosses its
///   neighbours, so the bar itself shows where it will land. Over another editor's
///   bar a line marks the gap it would drop into — a live move there would empty
///   the editor the drag started from, and so remove the view the drag is coming
///   from, while it is still in flight.
/// - **A context menu per tab**, asked of the delegate.
///
/// The mouse is taken over rather than passed to `super`. The control's own
/// tracking loop keeps every event until the button comes up, so a drag could
/// never start from inside it. A tab is selected on mouse-down instead — which
/// is when Xcode and Safari select one — and the action is still sent, so
/// accessibility's press and keyboard selection arrive at the same place.
@MainActor
final class EditorTabBar: NSSegmentedControl, NSDraggingSource {

    struct Item: Equatable {
        var title: String
        var image: NSImage?
        var toolTip: String?
        var isPinned: Bool
    }

    weak var delegate: EditorTabBarDelegate?

    private(set) var items: [Item] = []

    /// The tab under the pointer, which is the one the close button is over.
    private(set) var hoveredIndex: Int?

    /// The tab being dragged out of this bar, followed through the moves a drag
    /// within the bar makes. `nil` when no drag started here.
    private(set) var draggedIndex: Int?

    let closeButton: NSButton = TabCloseButton()

    /// Where a tab dragged in from another bar would drop.
    let insertionIndicator = NSView()

    /// The bar a drag in flight started from, held until the session ends.
    ///
    /// Dropping a tab into the other editor can close the editor it came from —
    /// it was that editor's last tab — and with it this bar, while the session is
    /// still going to tell it the drag ended. Nothing documents that a session
    /// keeps its source alive, so this does.
    private static var inFlight: EditorTabBar?

    private var pressedIndex: Int?
    private var pressLocation: NSPoint = .zero

    /// How far a press has to travel before it is a drag rather than a click.
    private static let dragThreshold: CGFloat = 4

    /// Measured against the control as drawn: the track's inset from the
    /// control's edges, which segments start inside.
    private static let trackInset: CGFloat = 2

    init() {
        super.init(frame: .zero)
        if #available(macOS 27.0, *) {
            role = .tabs
        }
        trackingMode = .selectOne
        controlSize = .large
        segmentDistribution = .fillEqually
        target = self
        action = #selector(segmentSelected)
        registerForDraggedTypes([.editorTab])

        closeButton.bezelStyle = .smallSquare
        closeButton.isBordered = false
        // Xcode's cross, 8 points in the middle of the circle. At 10 points medium
        // the symbol's cross is 8 points with a point to spare on every side of
        // its image (measured), so centring the image centres the cross — which
        // the symbol's own alignment rect, a text baseline's, does not.
        let cross = NSImage(
            systemSymbolName: "xmark", accessibilityDescription: String(localized: "Close Tab", bundle: .module)
        )?.withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        cross?.alignmentRect = NSRect(origin: .zero, size: cross?.size ?? .zero)
        closeButton.image = cross
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeHovered)
        closeButton.isHidden = true
        addSubview(closeButton)

        insertionIndicator.wantsLayer = true
        insertionIndicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        insertionIndicator.layer?.cornerRadius = 1
        insertionIndicator.isHidden = true
        addSubview(insertionIndicator)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("code-only")
    }

    // MARK: - Content

    /// Rebuilds the segments. Idempotent: every segment is rewritten, so nothing
    /// a previous configuration set survives into this one.
    func configure(items: [Item], selectedIndex: Int?) {
        self.items = items
        segmentCount = items.count
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: controlSize))
        for (index, item) in items.enumerated() {
            setLabel(item.title, forSegment: index)
            setImage(
                item.isPinned
                    ? NSImage(
                        systemSymbolName: "pin.fill",
                        accessibilityDescription: String(localized: "Pinned", bundle: .module))
                    : item.image,
                forSegment: index)
            setToolTip(item.toolTip ?? item.title, forSegment: index)
            // Zero is "size me with the others".
            setWidth(
                item.isPinned ? Self.pinnedWidth(for: item.title, font: font) : 0,
                forSegment: index)
        }
        selectedSegment = selectedIndex ?? -1
        if let hovered = hoveredIndex, hovered >= items.count { hoveredIndex = nil }
        needsLayout = true
    }

    /// As wide as its title and pin, and no wider: a pinned tab is kept for
    /// reaching, not for reading at length.
    private static func pinnedWidth(for title: String, font: NSFont) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: font]).width) + 44
    }

    // MARK: - Geometry

    /// The rectangle segment `index` occupies, in this view's coordinates.
    ///
    /// Arithmetic rather than a query, because the control publishes none: a
    /// pinned segment is the width it was given, and the rest share what is left
    /// equally — which is `fillEqually`'s definition, applied here the same way.
    func rect(forTabAt index: Int) -> NSRect {
        guard index >= 0, index < segmentCount else { return .zero }
        let track = bounds.insetBy(dx: Self.trackInset, dy: 0)
        let fixed = (0..<segmentCount).map { width(forSegment: $0) }
        let flexible = fixed.filter { $0 == 0 }.count
        let share = flexible > 0 ? max(0, track.width - fixed.reduce(0, +)) / CGFloat(flexible) : 0
        var x = track.minX
        for segment in 0..<index {
            x += fixed[segment] == 0 ? share : fixed[segment]
        }
        let width = fixed[index] == 0 ? share : fixed[index]
        return NSRect(x: x, y: bounds.minY, width: width, height: bounds.height)
    }

    /// The tab under `point`, or `nil` off every tab.
    func tabIndex(at point: NSPoint) -> Int? {
        (0..<segmentCount).first { rect(forTabAt: $0).contains(point) }
    }

    /// The gap nearest to `point`, as the index a tab dropped there would take.
    func insertionIndex(at point: NSPoint) -> Int {
        (0..<segmentCount).filter { rect(forTabAt: $0).midX < point.x }.count
    }

    override func layout() {
        super.layout()
        placeCloseButton()
    }

    private func placeCloseButton() {
        guard let hovered = hoveredIndex, hovered < items.count, !items[hovered].isPinned,
            draggedIndex == nil
        else {
            closeButton.isHidden = true
            return
        }
        let tab = rect(forTabAt: hovered)
        let side: CGFloat = 16
        closeButton.frame = NSRect(
            x: tab.minX + 8, y: tab.midY - side / 2, width: side, height: side)
        closeButton.isHidden = false
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        setHoveredIndex(tabIndex(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseEntered(with event: NSEvent) {
        setHoveredIndex(tabIndex(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredIndex(nil)
    }

    private func setHoveredIndex(_ index: Int?) {
        guard index != hoveredIndex else { return }
        hoveredIndex = index
        placeCloseButton()
    }

    @objc private func closeHovered() {
        guard let hovered = hoveredIndex else { return }
        delegate?.tabBar(self, didCloseTabAt: hovered)
    }

    // MARK: - Pressing and dragging

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = tabIndex(at: point) else { return }
        pressedIndex = index
        pressLocation = point
        guard index != selectedSegment else { return }
        selectedSegment = index
        segmentSelected()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed = pressedIndex else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - pressLocation.x, point.y - pressLocation.y) > Self.dragThreshold
        else { return }
        pressedIndex = nil
        beginDragging(tabAt: pressed, with: event)
    }

    override func mouseUp(with event: NSEvent) {
        pressedIndex = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let index = tabIndex(at: convert(event.locationInWindow, from: nil)) else {
            return nil
        }
        return delegate?.tabBar(self, menuForTabAt: index)
    }

    @objc private func segmentSelected() {
        guard selectedSegment >= 0 else { return }
        delegate?.tabBar(self, didSelectTabAt: selectedSegment)
    }

    private func beginDragging(tabAt index: Int, with event: NSEvent) {
        let tab = rect(forTabAt: index)
        let item = NSDraggingItem(pasteboardWriter: EditorTabDrag())
        item.setDraggingFrame(tab, contents: snapshot(of: tab))
        dragWillBegin(tabAt: index)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    /// The bar's half of a drag starting: which tab is in flight, and no close
    /// button while it is. Kept apart from the session, which is the window
    /// server's — the bar's state is everything a destination reads, and it is
    /// the same whether the pointer or a test is moving it.
    func dragWillBegin(tabAt index: Int) {
        draggedIndex = index
        placeCloseButton()
        Self.inFlight = self
    }

    /// The bar's half of a drag ending, however it ended.
    func dragDidEnd() {
        draggedIndex = nil
        placeCloseButton()
        Self.inFlight = nil
    }

    private func snapshot(of rect: NSRect) -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        dragDidEnd()
    }

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let source = sender.draggingSource as? EditorTabBar,
            let dragged = source.draggedIndex
        else { return [] }
        let point = convert(sender.draggingLocation, from: nil)

        guard source !== self else {
            // Live: the tab moves as soon as the pointer is over another one.
            let target = tabIndex(at: point) ?? (point.x < bounds.midX ? 0 : segmentCount - 1)
            if target != dragged,
                let landed = delegate?.tabBar(self, moveTabAt: dragged, of: self, to: target)
            {
                draggedIndex = landed
            }
            return .move
        }

        showInsertionIndicator(at: insertionIndex(at: point))
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        insertionIndicator.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        insertionIndicator.isHidden = true
        guard let source = sender.draggingSource as? EditorTabBar,
            let dragged = source.draggedIndex
        else { return false }
        // Already where it belongs: a drag within the bar moved it on the way.
        guard source !== self else { return true }
        let index = insertionIndex(at: convert(sender.draggingLocation, from: nil))
        return delegate?.tabBar(self, moveTabAt: dragged, of: source, to: index) != nil
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        insertionIndicator.isHidden = true
    }

    private func showInsertionIndicator(at index: Int) {
        let x =
            index < segmentCount
            ? rect(forTabAt: index).minX
            : rect(forTabAt: segmentCount - 1).maxX
        insertionIndicator.frame = NSRect(x: x - 1, y: 4, width: 2, height: bounds.height - 8)
        insertionIndicator.isHidden = false
    }
}

/// The close button's glyph, with the circle Xcode puts behind it while the
/// pointer is over it.
///
/// The circle is `tertiarySystemFill`: measured against Xcode's in the light
/// appearance — 16 points across, black at 4.7% over the tab — and the system
/// colour carries the dark value. It is the layer's background, which draws
/// under the glyph.
private final class TabCloseButton: NSButton {

    private var isPointerInside = false {
        didSet { updateCircle() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isPointerInside = true }
    override func mouseExited(with event: NSEvent) { isPointerInside = false }

    /// Moved to another tab or taken away, it is not under the pointer any more.
    override func viewDidHide() {
        super.viewDidHide()
        isPointerInside = false
    }

    override func layout() {
        super.layout()
        updateCircle()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateCircle()
    }

    private func updateCircle() {
        wantsLayer = true
        layer?.cornerRadius = bounds.height / 2
        guard isPointerInside else {
            layer?.backgroundColor = nil
            return
        }
        let fill: NSColor
        if #available(macOS 14.0, *) {
            fill = .tertiarySystemFill
        } else {
            fill = NSColor.labelColor.withAlphaComponent(0.047)
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill.cgColor
        }
    }
}

/// What a tab drag carries: nothing, on purpose. The tab is found through the
/// session's source, which is only ever a bar in this process — a tab has no
/// meaning to another application, so the type is not one it could read.
final class EditorTabDrag: NSObject, NSPasteboardWriting {

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [.editorTab]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        ""
    }
}

extension NSPasteboard.PasteboardType {
    static let editorTab = NSPasteboard.PasteboardType("com.ccterm.transcriptworkspace.tab")
}
