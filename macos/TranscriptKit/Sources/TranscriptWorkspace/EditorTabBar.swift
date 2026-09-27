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

/// An editor's row of tabs, the way Xcode's are: a capsule track with the
/// selected tab raised out of it in glass, and tabs that move under the pointer.
///
/// **Built from system parts.** The track is `secondarySystemFill` and the
/// selected tab is an `NSGlassEffectView` — measured against `NSSegmentedControl`
/// in its macOS 27 tabs role, which is the same two things: equal to a grey level
/// in both appearances, the glass taking care of an inactive window. What is
/// drawn here is only where each tab goes. A segmented control cannot be the bar
/// because its segments cannot move: Xcode's drag moves a tab.
///
/// **A drag, as Xcode's goes** (measured frame by frame off Xcode's own bar):
///
/// - **Within the bar** the tab stays in it, under the pointer, and a neighbour
///   whose middle it crosses slides into the place it left. Let go, it slides
///   into its own. No drag session: the mouse events are enough, and a session's
///   image would be a second copy of the tab.
/// - **Out of the bar**, far enough above or below it, the tab leaves as a drag
///   session carrying a small capsule of its title, and the tabs it left close up.
/// - **Over a bar** — another editor's, or its own again — the tabs open a gap
///   where it would drop, and it drops into the gap.
///
/// Only the drag moves anything. A tab added, closed or selected lands at once.
///
/// The tabs are tracked by identity, not position: a view per `Item.id`, so a
/// reorder moves views instead of relabelling them in place, and the dragged tab
/// is still the dragged tab after its index changes under it.
@MainActor
final class EditorTabBar: NSView, NSDraggingSource {

    struct Item: Equatable {
        /// Which tab this is, through moves.
        var id: ObjectIdentifier
        var title: String
        var image: NSImage?
        var toolTip: String?
        var isPinned: Bool
    }

    weak var delegate: EditorTabBarDelegate?

    private(set) var items: [Item] = []
    private(set) var selectedIndex: Int?

    /// The tab under the pointer, which is the one the close button is over.
    private(set) var hoveredIndex: Int?

    /// The tab being dragged out of this bar, wherever it has got to. `nil` when
    /// no drag started here, and once the tab has left for another bar.
    var draggedIndex: Int? {
        draggedID.flatMap { id in items.firstIndex { $0.id == id } }
    }

    /// Whether the dragged tab has left the bar as a drag session.
    private(set) var isDraggedTabOut = false

    /// Where a tab dragged over this bar would drop: the gap opened for it.
    private(set) var gapIndex: Int?

    let closeButton: NSButton = TabCloseButton()

    static let height: CGFloat = 28

    /// The bar a drag in flight started from, held until the session ends.
    ///
    /// Dropping a tab into the other editor can close the editor it came from —
    /// it was that editor's last tab — and with it this bar, while the session is
    /// still going to tell it the drag ended. Nothing documents that a session
    /// keeps its source alive, so this does.
    private static var inFlight: EditorTabBar?

    /// A tab's view and the two constraints that place it: where along the bar
    /// it starts, and how wide it is. A slide animates the two constants, which
    /// lays the tab out again on every frame — so its glass and its title follow
    /// its width as it changes, instead of being carried at the final width.
    private struct Tab {
        let view: EditorTabView
        let leading: NSLayoutConstraint
        let width: NSLayoutConstraint
    }

    private var tabs: [ObjectIdentifier: Tab] = [:]
    /// Tabs made since the tabs were last placed, which land where they go.
    private var unplaced: Set<ObjectIdentifier> = []
    private var draggedID: ObjectIdentifier?

    private var pressedIndex: Int?
    private var pressLocation: NSPoint = .zero
    /// Where along the dragged tab the pointer holds it, and where the pointer is.
    private var grabOffset: CGFloat = 0
    private var pointerX: CGFloat = 0

    /// The size the tabs were last placed for.
    private var placedSize: NSSize?

    /// How far a press has to travel before it is a drag rather than a click.
    private static let dragThreshold: CGFloat = 4

    init() {
        super.init(frame: .zero)
        wantsLayer = true
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("code-only")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
    }

    // MARK: - The track

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let fill: NSColor
        if #available(macOS 14.0, *) {
            fill = .secondarySystemFill
        } else {
            fill = NSColor.labelColor.withAlphaComponent(0.078)
        }
        layer?.backgroundColor = fill.cgColor
        layer?.cornerRadius = bounds.height / 2
    }

    // MARK: - Content

    /// Shows `items`, the one at `selectedIndex` selected. Idempotent. A change
    /// made while a drag is going on is the drag's, and slides; any other lands.
    func configure(items: [Item], selectedIndex: Int?) {
        self.items = items
        self.selectedIndex = selectedIndex
        let kept = Set(items.map(\.id))
        for (id, tab) in tabs where !kept.contains(id) {
            tab.view.removeFromSuperview()
            tabs[id] = nil
        }
        for (index, item) in items.enumerated() {
            if tabs[item.id] == nil {
                attach(EditorTabView(), as: item.id)
                unplaced.insert(item.id)
            }
            tabs[item.id]?.view.configure(with: item, isSelected: index == selectedIndex)
        }
        if let hovered = hoveredIndex, hovered >= items.count { hoveredIndex = nil }
        placeTabs(animated: draggedID != nil || gapIndex != nil)
    }

    /// Adds `view` as the tab `id`, over the tabs already there and under the
    /// close button, where it was if it was placed before.
    private func attach(_ view: EditorTabView, as id: ObjectIdentifier, at frame: NSRect = .zero) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view, positioned: .below, relativeTo: closeButton)
        let tab = Tab(
            view: view,
            leading: view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: frame.minX),
            width: view.widthAnchor.constraint(equalToConstant: frame.width))
        NSLayoutConstraint.activate([
            tab.leading, tab.width,
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        tabs[id] = tab
    }

    /// Puts the tab over its neighbours, to pass over them. Re-adding a view is
    /// how AppKit reorders one, and it takes the view's constraints with it.
    private func raise(_ id: ObjectIdentifier) {
        guard let tab = tabs[id] else { return }
        tab.view.removeFromSuperview()
        attach(
            tab.view, as: id,
            at: NSRect(x: tab.leading.constant, y: 0, width: tab.width.constant, height: 0))
    }

    private func tab(at index: Int) -> Tab? {
        tabs[items[index].id]
    }

    // MARK: - Geometry

    /// Left to right over the bar, a rect for each of `indices`; `gap` puts an
    /// empty place the width of an unpinned tab before the `gap`-th of them.
    ///
    /// A pinned tab is as wide as its title and the rest share what is left. The
    /// tabs run end to end of the track, as the segmented control's segments do:
    /// the margin is inside each tab, around its glass.
    private func slots(for indices: [Int], gap: Int? = nil) -> [NSRect] {
        let fixed = indices.map { items[$0].isPinned ? Self.pinnedWidth(for: items[$0].title) : 0 }
        let flexible = fixed.filter { $0 == 0 }.count + (gap == nil ? 0 : 1)
        let share = flexible > 0 ? max(0, bounds.width - fixed.reduce(0, +)) / CGFloat(flexible) : 0
        var x = bounds.minX
        var rects: [NSRect] = []
        for (position, width) in fixed.enumerated() {
            if position == gap { x += share }
            let width = width == 0 ? share : width
            rects.append(NSRect(x: x, y: bounds.minY, width: width, height: bounds.height))
            x += width
        }
        return rects
    }

    /// Where the tab at `index` rests, with no drag going on.
    func rect(forTabAt index: Int) -> NSRect {
        guard items.indices.contains(index) else { return .zero }
        return slots(for: Array(items.indices))[index]
    }

    /// The tab under `point`, or `nil` off every tab.
    func tabIndex(at point: NSPoint) -> Int? {
        items.indices.first { rect(forTabAt: $0).contains(point) }
    }

    /// The tabs in the bar, which a tab dragged out of it is not.
    private var shownIndices: [Int] {
        items.indices.filter { !(isDraggedTabOut && $0 == draggedIndex) }
    }

    /// The gap nearest to `point` among the tabs in the bar, as the index a tab
    /// dropped there would take.
    private func insertionIndex(at point: NSPoint) -> Int {
        slots(for: shownIndices).filter { $0.midX < point.x }.count
    }

    /// As wide as its title and pin, and no wider: a pinned tab is kept for
    /// reaching, not for reading at length.
    private static func pinnedWidth(for title: String) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: EditorTabView.font]).width) + 44
    }

    // MARK: - Placing the tabs

    /// A new size places the tabs for it, before the pass lays them out.
    override func layout() {
        if bounds.size != placedSize { placeTabs(animated: false) }
        super.layout()
    }

    /// Where the tab in hand is: under the pointer, held where it was picked up,
    /// and kept on the track.
    private func heldFrame(in slot: NSRect) -> NSRect {
        var frame = slot
        frame.origin.x = min(max(pointerX - grabOffset, bounds.minX), bounds.maxX - slot.width)
        return frame
    }

    /// Puts every tab where it goes now: at rest, bent by a drag. The tab in hand
    /// follows the pointer and never animates; the rest slide when `animated`,
    /// except a tab new to the bar, which lands where it goes.
    private func placeTabs(animated: Bool) {
        placedSize = bounds.size
        let shown = shownIndices
        var slides: [(Tab, NSRect)] = []
        for (index, slot) in zip(shown, slots(for: shown, gap: gapIndex)) {
            guard let tab = tab(at: index) else { continue }
            tab.view.isHidden = false
            if index == draggedIndex {
                place(tab, at: heldFrame(in: slot))
            } else if animated, !unplaced.contains(items[index].id) {
                slides.append((tab, slot))
            } else {
                place(tab, at: slot)
            }
        }
        unplaced.removeAll()
        if isDraggedTabOut, let dragged = draggedIndex { tab(at: dragged)?.view.isHidden = true }
        if !slides.isEmpty {
            NSAnimationContext.runAnimationGroup { context in
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { context.duration = 0 }
                for (tab, frame) in slides {
                    tab.leading.animator().constant = frame.minX
                    tab.width.animator().constant = frame.width
                }
            }
        }
        placeCloseButton()
    }

    private func place(_ tab: Tab, at frame: NSRect) {
        tab.leading.constant = frame.minX
        tab.width.constant = frame.width
    }

    private func placeCloseButton() {
        guard let hovered = hoveredIndex, items.indices.contains(hovered), !items[hovered].isPinned,
            draggedID == nil
        else {
            closeButton.isHidden = true
            return
        }
        // 8 points into the glass, which is 2 into the tab.
        let side: CGFloat = 16
        let tab = rect(forTabAt: hovered)
        closeButton.frame = NSRect(
            x: tab.minX + 10, y: tab.midY - side / 2, width: side, height: side)
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

    // MARK: - Pressing and dragging within the bar

    /// Selects on mouse-down, which is when Xcode and Safari select a tab.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = tabIndex(at: point) else { return }
        pressedIndex = index
        pressLocation = point
        select(index)
    }

    private func select(_ index: Int) {
        guard index != selectedIndex else { return }
        delegate?.tabBar(self, didSelectTabAt: index)
    }

    // MARK: Accessibility — a tab group of radio buttons, one per tab

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .tabGroup }

    /// A tab pressed through accessibility, as VoiceOver presses one.
    fileprivate func press(_ tab: EditorTabView) {
        guard let index = items.indices.first(where: { self.tab(at: $0)?.view === tab }) else { return }
        select(index)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if draggedID == nil {
            guard let pressed = pressedIndex, let tab = tab(at: pressed),
                hypot(point.x - pressLocation.x, point.y - pressLocation.y) > Self.dragThreshold
            else { return }
            draggedID = items[pressed].id
            grabOffset = pressLocation.x - tab.leading.constant
            raise(items[pressed].id)
        }
        guard let dragged = draggedIndex, !isDraggedTabOut else { return }
        // Far enough above or below, it has left the bar.
        guard abs(point.y - bounds.midY) <= bounds.height else {
            pressedIndex = nil
            beginDraggingSession(tabAt: dragged, with: event)
            return
        }
        pointerX = point.x
        // Past every tab whose middle its edge has crossed: the leading edge for a
        // tab before it, the trailing edge for one after. Held on the track, it
        // can reach either end.
        let rests = slots(for: Array(items.indices))
        let held = heldFrame(in: rests[dragged])
        let target = items.indices.filter { index in
            index < dragged ? rests[index].midX < held.minX : index > dragged && rests[index].midX < held.maxX
        }.count
        if target != dragged {
            _ = delegate?.tabBar(self, moveTabAt: dragged, of: self, to: target)
        }
        placeTabs(animated: true)
    }

    /// Let go within the bar: the tab slides into its place.
    override func mouseUp(with event: NSEvent) {
        pressedIndex = nil
        guard draggedID != nil, !isDraggedTabOut else { return }
        draggedID = nil
        placeTabs(animated: true)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let index = tabIndex(at: convert(event.locationInWindow, from: nil)) else {
            return nil
        }
        return delegate?.tabBar(self, menuForTabAt: index)
    }

    // MARK: - Dragging out of the bar

    private func beginDraggingSession(tabAt index: Int, with event: NSEvent) {
        let image = Self.dragImage(for: items[index])
        let point = convert(event.locationInWindow, from: nil)
        let item = NSDraggingItem(pasteboardWriter: EditorTabDrag())
        item.setDraggingFrame(
            NSRect(
                x: point.x - image.size.width / 2, y: point.y - image.size.height / 2,
                width: image.size.width, height: image.size.height),
            contents: image)
        dragWillBegin(tabAt: index)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    /// The bar's half of a tab leaving it as a drag session: the tab is out, and
    /// the tabs it left close up. Kept apart from the session, which is the
    /// window server's — the bar's state is everything a destination reads, and
    /// it is the same whether the pointer or a test is moving it.
    func dragWillBegin(tabAt index: Int) {
        draggedID = items[index].id
        isDraggedTabOut = true
        Self.inFlight = self
        placeTabs(animated: true)
    }

    /// The bar's half of a drag ending, however it ended. A tab still here comes
    /// back into its place.
    func dragDidEnd() {
        draggedID = nil
        isDraggedTabOut = false
        Self.inFlight = nil
        placeTabs(animated: true)
    }

    /// What follows the pointer out of the bar: the tab's title and image in a
    /// small capsule, which is what Xcode's drag carries rather than the tab.
    private static func dragImage(for item: Item) -> NSImage {
        let font = EditorTabView.font
        let title = item.title as NSString
        let titleSize = title.size(withAttributes: [.font: font])
        let icon = item.image.map { $0.withSymbolConfiguration(.init(paletteColors: [.labelColor])) ?? $0 }
        let (height, padding, spacing, side): (CGFloat, CGFloat, CGFloat, CGFloat) = (26, 12, 5, 16)
        let width = ceil(2 * padding + (icon == nil ? 0 : side + spacing) + titleSize.width)
        return NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let capsule = NSBezierPath(
                roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: (height - 1) / 2, yRadius: (height - 1) / 2)
            NSColor.controlBackgroundColor.setFill()
            capsule.fill()
            NSColor.separatorColor.setStroke()
            capsule.stroke()
            var x = padding
            if let icon {
                icon.draw(in: NSRect(x: x, y: (height - side) / 2, width: side, height: side))
                x += side + spacing
            }
            title.draw(
                at: NSPoint(x: x, y: (height - titleSize.height) / 2),
                withAttributes: [.font: font, .foregroundColor: NSColor.labelColor])
            return true
        }
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

    /// A tab over the bar opens a gap where it would drop.
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let source = sender.draggingSource as? EditorTabBar, source.draggedIndex != nil else {
            return []
        }
        let gap = insertionIndex(at: convert(sender.draggingLocation, from: nil))
        if gap != gapIndex {
            gapIndex = gap
            placeTabs(animated: true)
        }
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        closeGap()
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        closeGap()
    }

    /// Drops the tab into the gap: the gap closes as the tab takes its place, so
    /// nothing moves. One from this bar is back in it from here on.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let source = sender.draggingSource as? EditorTabBar, let dragged = source.draggedIndex
        else {
            closeGap()
            return false
        }
        let gap = gapIndex ?? insertionIndex(at: convert(sender.draggingLocation, from: nil))
        gapIndex = nil
        if source === self {
            draggedID = nil
            isDraggedTabOut = false
        }
        let moved = delegate?.tabBar(self, moveTabAt: dragged, of: source, to: gap) != nil
        placeTabs(animated: true)
        return moved
    }

    private func closeGap() {
        guard gapIndex != nil else { return }
        gapIndex = nil
        placeTabs(animated: true)
    }
}

/// One tab: its image and title, and the glass it sits in while selected.
///
/// Not hit by the mouse — the bar takes every event, since a press on a tab is
/// the start of a drag the bar runs.
@MainActor
private final class EditorTabView: NSView {

    /// The tabs-role segmented control's, at `.large`.
    static let font = NSFont.systemFont(ofSize: 13)

    private let background: NSView = {
        if #available(macOS 26.0, *) {
            return NSGlassEffectView()
        }
        let box = NSBox()
        box.boxType = .custom
        box.fillColor = .controlBackgroundColor
        box.borderColor = .separatorColor
        box.borderWidth = 0.5
        return box
    }()

    private let imageView: NSImageView = {
        let view = NSImageView()
        view.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        // The segmented control's image is the title's colour, not a lighter one.
        view.contentTintColor = .labelColor
        return view
    }()

    private let label: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = EditorTabView.font
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    private var isSelected = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(background)
        let content = NSStackView(views: [imageView, label])
        content.orientation = .horizontal
        // 4 points from the symbol's ink to the title's, as measured on the
        // segmented control; the symbol's image carries 2 of them on its side.
        content.spacing = 2
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        // Room at the leading edge for the close button, and as much at the other.
        let inset: CGFloat = 28
        let centre = content.centerXAnchor.constraint(equalTo: centerXAnchor)
        centre.priority = .defaultHigh
        NSLayoutConstraint.activate([
            centre,
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("code-only")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The glass stands 2 points in from every edge of the tab, and draws half a
    /// point past its frame — so it shows 1.5 points in, as the segmented
    /// control's selected segment does.
    override func layout() {
        super.layout()
        background.frame = bounds.insetBy(dx: 2, dy: 2)
        if #available(macOS 26.0, *), let glass = background as? NSGlassEffectView {
            glass.cornerRadius = background.frame.height / 2
        } else {
            (background as? NSBox)?.cornerRadius = background.frame.height / 2
        }
    }

    func configure(with item: EditorTabBar.Item, isSelected: Bool) {
        self.isSelected = isSelected
        background.isHidden = !isSelected
        label.stringValue = item.title
        imageView.image =
            item.isPinned
            ? NSImage(
                systemSymbolName: "pin.fill",
                accessibilityDescription: String(localized: "Pinned", bundle: .module))
            : item.image
        imageView.isHidden = imageView.image == nil
        toolTip = item.toolTip ?? item.title
        setAccessibilityLabel(item.title)
    }

    // MARK: Accessibility — a tab is a radio button in the bar's group

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
    override func accessibilityValue() -> Any? { NSNumber(value: isSelected) }

    override func accessibilityPerformPress() -> Bool {
        guard let bar = superview as? EditorTabBar else { return false }
        bar.press(self)
        return true
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
