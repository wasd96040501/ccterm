import AppKit

/// A `MenuContent` that is a menu, not a panel (`.lv-menu` without `.panel`:
/// Effort, Permission Mode, the folder), as a real `NSMenu`: the system's
/// tracking, keys, type-select and chrome, and each row the design's own —
/// the same cells the panel draws (`MenuItemCell`, `MenuTitleCell`,
/// `MenuSeparatorCell`) as the items' views, at the width the panel would be.
///
/// AppKit sends `menuDidClose` before the chosen item's action, so the owner
/// hears the menu close and then the choice, as from the panel.
@MainActor
package final class SystemMenu: NSObject, NSMenuDelegate {
    var onChoose: ((MenuContent.Item) -> Void)?
    var onClose: (() -> Void)?

    package let menu = NSMenu()
    private(set) var isShown = false
    private var content = MenuContent(rows: [])

    package override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        menu.showsStateColumn = false
    }

    package func configure(with content: MenuContent) {
        self.content = content
        // As wide as its widest row (`.lv-menu`).
        let width = MenuMetrics.width(of: content)
        menu.removeAllItems()
        for row in content.rows {
            let height = MenuMetrics.height(of: row, width: width, content: content)
            let frame = NSRect(x: 0, y: 0, width: width, height: height)
            let menuItem = NSMenuItem()
            switch row {
            case .separator:
                menuItem.view = SystemMenuRowView(cell: MenuSeparatorCell(frame: frame), frame: frame)
                menuItem.isEnabled = false
            case .header(.title(let title, let hint)):
                let cell = MenuTitleCell(frame: frame)
                cell.configure(title, hint: hint)
                menuItem.view = SystemMenuRowView(cell: cell, frame: frame)
                menuItem.isEnabled = false
            case .header(.account):
                // An account's head belongs to a panel; a menu never has one.
                continue
            case .item(let item):
                let cell = MenuItemCell(frame: frame)
                cell.configure(item, glyphColumn: content.hasGlyphColumn)
                cell.onToggle = { [weak self] _ in self?.report(item) }
                let view = SystemMenuRowView(cell: cell, frame: frame)
                view.onClick = { [weak self, weak menuItem] in
                    guard let self, let menuItem else { return }
                    self.click(menuItem)
                }
                menuItem.view = view
                // Type-select reads the title even under a view.
                menuItem.title = item.title
                menuItem.isEnabled = item.isEnabled
                menuItem.representedObject = item
                menuItem.target = self
                menuItem.action = #selector(choose(_:))
                menuItem.toolTip = item.toolTip
            }
            menu.addItem(menuItem)
        }
    }

    /// Pops the menu up `gap` from `control` on `side` — its leading edge
    /// `leadingOffset` from the control's — and returns when it closes. The
    /// menu moves itself to fit the screen.
    package func popUp(from control: NSView, on side: MenuPopup.Side, gap: CGFloat, leadingOffset: CGFloat) {
        let bounds = control.bounds
        let below = control.isFlipped ? bounds.maxY + gap : bounds.minY - gap
        let above = control.isFlipped ? bounds.minY - gap - menu.size.height : bounds.maxY + gap + menu.size.height
        let point = NSPoint(x: bounds.minX + leadingOffset, y: side == .below ? below : above)
        menu.popUp(positioning: nil, at: point, in: control)
    }

    func close() {
        guard isShown else { return }
        menu.cancelTracking()
    }

    // MARK: - Choosing

    /// The item's action: Return on it, or a click (`click`).
    @objc private func choose(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? MenuContent.Item else { return }
        report(item)
    }

    /// A click on an item's view: the menu sends no action for a view, so the
    /// item asks for it — after the menu closes, unless the item keeps it open.
    private func click(_ menuItem: NSMenuItem) {
        guard menuItem.isEnabled, let item = menuItem.representedObject as? MenuContent.Item else { return }
        if item.keepsMenuOpen {
            report(item)
            return
        }
        menu.cancelTracking()
        menu.performActionForItem(at: menu.index(of: menuItem))
    }

    private func report(_ item: MenuContent.Item) {
        onChoose?(item)
    }

    // MARK: - NSMenuDelegate

    package func menuWillOpen(_ menu: NSMenu) {
        isShown = true
    }

    package func menuDidClose(_ menu: NSMenu) {
        isShown = false
        onClose?()
    }
}

/// A row of a `SystemMenu`: the design's cell, under the accent fill while
/// the menu highlights its item (`.mi:hover`, 5 in from either edge).
final class SystemMenuRowView: NSView {
    var onClick: (() -> Void)?

    private let cell: NSView
    private let highlight = CALayer()

    init(cell: NSView, frame: NSRect) {
        self.cell = cell
        super.init(frame: frame)
        wantsLayer = true
        highlight.cornerRadius = CornerRadius.row
        highlight.cornerCurve = .continuous
        layer?.addSublayer(highlight)
        cell.frame = bounds
        cell.autoresizingMask = [.width, .height]
        addSubview(cell)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private var isHighlighted: Bool { enclosingMenuItem?.isHighlighted ?? false }

    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.frame = bounds.insetBy(dx: MenuMetrics.inset, dy: 0)
        CATransaction.commit()
    }

    override func updateLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.plain.performAsCurrentDrawingAppearance {
            highlight.backgroundColor = isHighlighted ? NSColor.controlAccentColor.cgColor : nil
        }
        CATransaction.commit()
        (cell as? NSTableCellView)?.backgroundStyle = isHighlighted ? .emphasized : .normal
    }

    override func mouseUp(with event: NSEvent) {
        onClick?()
    }
}
