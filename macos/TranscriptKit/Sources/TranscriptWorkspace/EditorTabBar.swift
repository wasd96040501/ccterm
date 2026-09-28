import AppKit

/// What a reader did to an editor's tabs, reported to the group that owns them.
///
/// The bar holds no tabs of its own — it is handed `Item`s and reports indexes —
/// so every answer here is the group's to give.
@MainActor
protocol EditorTabBarDelegate: AnyObject {

    func tabBar(_ tabBar: EditorTabBar, didSelectTabAt index: Int)

    func tabBar(_ tabBar: EditorTabBar, didCloseTabAt index: Int)

    func tabBar(_ tabBar: EditorTabBar, didDoubleClickTabAt index: Int)

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

    /// What the tab at `index` shows once it has been pulled out of the bar: its
    /// content as it is now, or `nil` to go on showing the tab. `NSTableView`'s
    /// `dragImageForRows(with:tableColumns:event:offset:)`, asked of the party
    /// that holds the content; the bar frames it.
    func tabBar(_ tabBar: EditorTabBar, draggingImageForTabAt index: Int) -> NSImage?
}

/// An editor's row of tabs: a capsule track with the selected tab raised out of
/// it in glass, as Xcode's are, and tabs that light up and move under the
/// pointer as Safari's do.
///
/// **Built from system parts.** The track is `secondarySystemFill` and the
/// selected tab is an `NSGlassEffectView` — measured against `NSSegmentedControl`
/// in its macOS 27 tabs role, which is the same two things: equal to a grey level
/// in both appearances, the glass taking care of an inactive window. What is
/// drawn here is only where each tab goes. A segmented control cannot be the bar
/// because its segments cannot move: Xcode's drag moves a tab.
///
/// **A drag, as Safari's goes** (measured frame by frame off Xcode's bar and
/// Safari's):
///
/// - **Within the bar** the tab stays in it, under the pointer, and a neighbour
///   whose middle it crosses slides into the place it left. Let go, it slides
///   into its own place. No drag session: the
///   mouse events are enough, and a session's image would be a second copy of
///   the tab.
/// - **Out of the bar**, pulled to the edge of it, the tab becomes a drag
///   session while still over the bar, so the bar shows it as the tab where it
///   was; leaving the bar, AppKit turns it into a small picture of its content,
///   centred on the pointer, and the tabs it left close up.
/// - **Over a bar** — another editor's, or its own again — it is a tab again, the
///   tabs open a gap where it would drop, and it drops into the gap.
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
        /// The temporary tab, its title in italics.
        var isPreview = false
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
    /// Where each tab was last sent, so placing the tabs twice in one event — a
    /// reorder drag does, once through the move's `configure` and once after it —
    /// leaves a slide already heading there alone instead of restarting it.
    private var destinations: [ObjectIdentifier: NSRect] = [:]
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
        // Safari's: a 12-point disc with the cross cut out of it, which at 12 points
        // regular the symbol is (measured, ink and cross both). Centring its image
        // centres the disc — which the symbol's own alignment rect, a text
        // baseline's, does not.
        let cross = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: String(localized: "Close Tab", bundle: .module)
        )?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        cross?.alignmentRect = NSRect(origin: .zero, size: cross?.size ?? .zero)
        closeButton.image = cross
        // Safari's measures 80% of the ink, a shade under a label's 85%; the label
        // colour is the system's, and follows the appearance.
        closeButton.contentTintColor = .labelColor
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
            destinations[id] = nil
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
    /// how AppKit reorders one, and it takes the constraints to the bar with it —
    /// but not the width, which is the view's own and would stay to fight the new
    /// one.
    private func raise(_ id: ObjectIdentifier) {
        guard let tab = tabs[id] else { return }
        tab.width.isActive = false
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

    /// The place a tab dropped at `gap` would take: between the tabs either side
    /// of it, or the track's end.
    private func gapRect(at gap: Int) -> NSRect {
        let rects = slots(for: shownIndices, gap: gap)
        let minX = gap > 0 && gap <= rects.count ? rects[gap - 1].maxX : bounds.minX
        let maxX = gap < rects.count ? rects[gap].minX : bounds.maxX
        return NSRect(x: minX, y: bounds.minY, width: maxX - minX, height: bounds.height)
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
    /// and kept on the track — along it only, so that it leaves the bar all at
    /// once, as the picture of its content, rather than being seen to drift off.
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
            let id = items[index].id
            tab.view.isHidden = false
            if index == draggedIndex {
                place(tab, at: heldFrame(in: slot))
                destinations[id] = nil
            } else if animated, !unplaced.contains(id) {
                if destinations[id] != slot { slides.append((tab, slot)) }
                destinations[id] = slot
            } else {
                place(tab, at: slot)
                destinations[id] = slot
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
        showHover()
    }

    private func place(_ tab: Tab, at frame: NSRect) {
        tab.leading.constant = frame.minX
        tab.width.constant = frame.width
    }

    /// The hovered tab lights up and shows its close button, Safari's way; no tab
    /// does while one is being dragged.
    private func showHover() {
        let hovered = draggedID == nil ? hoveredIndex.flatMap { items.indices.contains($0) ? $0 : nil } : nil
        for (index, item) in items.enumerated() {
            tabs[item.id]?.view.isHovered = index == hovered
        }
        guard let hovered, !items[hovered].isPinned else {
            closeButton.isHidden = true
            return
        }
        // On the centre of the glass's leading end, as Safari's sits on its
        // capsule's: the glass is a capsule 2 points in from the tab, so its end is
        // a half circle centred half the tab's height in from the tab's edge.
        let side: CGFloat = 18
        let tab = rect(forTabAt: hovered)
        closeButton.frame = NSRect(
            x: tab.minX + tab.height / 2 - side / 2, y: tab.midY - side / 2, width: side, height: side)
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
        showHover()
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
        if event.clickCount == 2 {
            delegate?.tabBar(self, didDoubleClickTabAt: index)
        }
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
        // At the edge of the bar and still over it, it leaves as a drag session:
        // the bar is the first place the drag is over, and shows it as the tab it
        // was, so leaving the bar is the drag's own change to the picture, with
        // AppKit's animation. Past the edge, it would start as the picture.
        guard abs(point.y - bounds.midY) < bounds.height / 2 - 2 else {
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

    /// Pulled out, the tab leaves as a picture of its content, centred on the
    /// pointer — what the drag shows wherever no bar has said otherwise. Over a
    /// bar it is a tab again, which is the bar's to say
    /// (`updateDraggingItemsForDrag(_:)`), and AppKit returns it to this when the
    /// drag leaves.
    ///
    /// In formation `.none`: the items keep the frame they are given. The
    /// formation is what a drag looks like away from its source and from any
    /// destination, and left to the system a picture shrank as it left the bar.
    private func beginDraggingSession(tabAt index: Int, with event: NSEvent) {
        let thumbnail = Self.thumbnail(of: delegate?.tabBar(self, draggingImageForTabAt: index))
        let point = convert(event.locationInWindow, from: nil)
        let size = thumbnail.size
        let item = NSDraggingItem(pasteboardWriter: EditorTabDrag())
        item.setDraggingFrame(
            NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
            contents: thumbnail)
        dragWillBegin(tabAt: index)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.draggingFormation = .none
    }

    /// The bar's half of a tab leaving it as a drag session: the tab is out, and
    /// the place it left stays open as the gap the drag is over, until the drag
    /// leaves the bar and the tabs close up. Kept apart from the session, which
    /// is the window server's — the bar's state is everything a destination
    /// reads, and it is the same whether the pointer or a test is moving it.
    func dragWillBegin(tabAt index: Int) {
        draggedID = items[index].id
        isDraggedTabOut = true
        gapIndex = index
        Self.inFlight = self
        placeTabs(animated: true)
    }

    /// The bar's half of a drag ending, however it ended. A tab still here comes
    /// back into its place, and no gap is left open for it.
    func dragDidEnd() {
        draggedID = nil
        isDraggedTabOut = false
        gapIndex = nil
        Self.inFlight = nil
        placeTabs(animated: true)
    }

    /// The tab as a drag carries it over a bar it could drop into: a capsule of
    /// `size` with its image and title in the middle.
    private static func dragImage(for item: Item, size: NSSize) -> NSImage {
        let font = EditorTabView.font
        let icon = item.image.map { $0.withSymbolConfiguration(.init(paletteColors: [.labelColor])) ?? $0 }
        let (spacing, side): (CGFloat, CGFloat) = (4, 16)
        return NSImage(size: size, flipped: false) { rect in
            let radius = (rect.height - 1) / 2
            let capsule = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            NSColor.controlBackgroundColor.setFill()
            capsule.fill()
            NSColor.separatorColor.setStroke()
            capsule.stroke()
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
            ]
            let title = item.title as NSString
            let room = rect.width - 2 * rect.height - (icon == nil ? 0 : side + spacing)
            let titleSize = title.size(withAttributes: attributes)
            let titleWidth = min(ceil(titleSize.width), max(0, room))
            var x = rect.midX - (titleWidth + (icon == nil ? 0 : side + spacing)) / 2
            if let icon {
                icon.draw(in: NSRect(x: x, y: rect.midY - side / 2, width: side, height: side))
                x += side + spacing
            }
            title.draw(
                in: NSRect(x: x, y: rect.midY - titleSize.height / 2, width: titleWidth, height: titleSize.height),
                withAttributes: attributes)
            return true
        }
    }

    /// Content as Safari carries a page pulled out of its bar: small — 112 points
    /// across, measured — its top, in a thin frame; an empty card for a tab with
    /// no content to show.
    private static func thumbnail(of content: NSImage?) -> NSImage {
        let width: CGFloat = 112
        let aspect = content.map { $0.size.width > 0 ? $0.size.height / $0.size.width : 0 } ?? 0
        let size = NSSize(width: width, height: round(width * min(max(aspect, 0.5), 0.75)))
        return NSImage(size: size, flipped: false) { frame in
            let outline = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
            NSColor.windowBackgroundColor.setFill()
            outline.fill()
            if let content {
                NSGraphicsContext.saveGraphicsState()
                outline.addClip()
                // Filling the width, from the top down.
                let scale = frame.width / max(content.size.width, 1)
                let drawn = NSSize(width: frame.width, height: content.size.height * scale)
                content.draw(
                    in: NSRect(x: frame.minX, y: frame.maxY - drawn.height, width: drawn.width, height: drawn.height))
                NSGraphicsContext.restoreGraphicsState()
            }
            NSColor.separatorColor.setStroke()
            let border = NSBezierPath(roundedRect: frame.insetBy(dx: 0.25, dy: 0.25), xRadius: 6, yRadius: 6)
            border.lineWidth = 0.5
            border.stroke()
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

    /// Over the bar, the picture is a tab again: in the bar's row, as wide as
    /// the gap it would drop into, and held along its length where it was picked
    /// up — so over its own bar, as the drag begins, it is exactly the tab it
    /// was. Changed here, when AppKit says a drop here is likely enough to show,
    /// rather than on entering; AppKit takes the change off when the drag
    /// leaves, and that is the tab turning into the picture.
    override func updateDraggingItemsForDrag(_ sender: NSDraggingInfo?) {
        guard let sender, let source = sender.draggingSource as? EditorTabBar,
            let dragged = source.draggedIndex, let gap = gapIndex
        else { return }
        let glass = gapRect(at: gap).insetBy(dx: 2, dy: 2)
        let tab = Self.dragImage(for: source.items[dragged], size: glass.size)
        let along = source.grabOffset / max(source.rect(forTabAt: dragged).width, 1)
        let pointer = convert(sender.draggingLocation, from: nil)
        let frame = NSRect(
            x: pointer.x - glass.width * along, y: glass.minY, width: glass.width, height: glass.height)
        sender.enumerateDraggingItems(
            options: [], for: self, classes: [NSPasteboardItem.self], searchOptions: [:]
        ) { item, _, _ in
            item.setDraggingFrame(frame, contents: tab)
        }
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

    /// The hover: a capsule the glass's size, over it on the selected tab and on
    /// the track on any other. Measured off Safari, black at about 4% over the
    /// track and 2% over the glass; the system's fills one step apart carry both,
    /// and the dark appearance.
    private let hoverFill: NSBox = {
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 0
        box.isHidden = true
        return box
    }()

    var isHovered = false {
        didSet { hoverFill.isHidden = !isHovered }
    }

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
        addSubview(hoverFill)
        let content = NSStackView(views: [imageView, label])
        content.orientation = .horizontal
        // 4 points from the symbol's ink to the title's, as measured on the
        // segmented control; the symbol's image carries 2 of them on its side.
        content.spacing = 2
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        // Room at the leading edge for the close button, and as much at the other.
        // Short of required: a tab squeezed narrower than the two, as a new one is
        // before it is placed, clips its content rather than breaking the layout.
        let inset: CGFloat = 28
        let centre = content.centerXAnchor.constraint(equalTo: centerXAnchor)
        centre.priority = .defaultHigh
        let leading = content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: inset)
        let trailing = content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset)
        leading.priority = .required - 1
        trailing.priority = .required - 1
        NSLayoutConstraint.activate([
            centre,
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            leading, trailing,
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
        hoverFill.frame = background.frame
        hoverFill.cornerRadius = background.frame.height / 2
        if #available(macOS 26.0, *), let glass = background as? NSGlassEffectView {
            glass.cornerRadius = background.frame.height / 2
        } else {
            (background as? NSBox)?.cornerRadius = background.frame.height / 2
        }
    }

    func configure(with item: EditorTabBar.Item, isSelected: Bool) {
        self.isSelected = isSelected
        background.isHidden = !isSelected
        hoverFill.fillColor = isSelected ? .tabHoverOverGlass : .tabHover
        label.stringValue = item.title
        label.font =
            item.isPreview ? NSFontManager.shared.convert(Self.font, toHaveTrait: .italicFontMask) : Self.font
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

/// The close button: Safari's disc, in a halo while the pointer is over it and a
/// deeper one while it is pressed.
///
/// Safari's halo is the tab's own hover fill, 20 points across its 30-point
/// capsule, and it does not change on a press; the press is ours, one step deeper
/// in the same family of system fills. Drawn under the glyph in `draw(_:)`, where
/// a button reads its cell's highlight.
private final class TabCloseButton: NSButton {

    private var isPointerInside = false {
        didSet { needsDisplay = true }
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

    override func draw(_ dirtyRect: NSRect) {
        if let halo: NSColor = isHighlighted ? .tabPressed : isPointerInside ? .tabHover : nil {
            halo.setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
        super.draw(dirtyRect)
    }
}

extension NSColor {

    /// A tab, or the close button, under the pointer.
    fileprivate static var tabHover: NSColor {
        if #available(macOS 14.0, *) { return .tertiarySystemFill }
        return NSColor.labelColor.withAlphaComponent(0.047)
    }

    /// The selected tab under the pointer: over the glass, a step lighter, as Safari's.
    fileprivate static var tabHoverOverGlass: NSColor {
        if #available(macOS 14.0, *) { return .quaternarySystemFill }
        return NSColor.labelColor.withAlphaComponent(0.027)
    }

    /// The close button pressed.
    fileprivate static var tabPressed: NSColor {
        if #available(macOS 14.0, *) { return .systemFill }
        return NSColor.labelColor.withAlphaComponent(0.098)
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
