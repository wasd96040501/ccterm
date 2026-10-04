import AppKit

/// Puts a pop-up on screen against the control that opens it (design 08,
/// `MENU.place`): 4 pt from the control, its leading edge 4 pt before the
/// control's, on the preferred side if it fits, else the other.
///
/// What it is follows the design's tree: a menu (`.lv-menu` — Effort,
/// Permission Mode, the folder) is a real `NSMenu` (`SystemMenu`), the
/// system's tracking, keys and chrome with the design's rows; a panel
/// (`.lv-menu.panel` — the branch picker's filter, the model list's sticky
/// heads, its 360-pt scroll and the Fast Mode under it, none of which a menu
/// has) is `MenuPanelViewController` in a `MenuPopup`, its list shortened to
/// fit the roomier side (never under 120 pt), taking the keyboard and closing
/// when it loses it. Both draw the same rows.
///
/// Choosing an item closes it first and then reports, unless the item keeps
/// the menu open (a switch, *N More Models*): then the owner calls `update`
/// with what changed.
@MainActor
public final class MenuPanel: NSObject {
    /// An item was chosen.
    public var onChoose: ((MenuContent.Item) -> Void)?
    /// The filter field's words changed; the owner answers with `update`.
    public var onFilter: ((String) -> Void)?
    /// The menu closed, however it closed.
    public var onClose: (() -> Void)?

    /// The shortest a list is cut to when the screen has no room.
    static let minimumListHeight: CGFloat = 120

    private let controller = MenuPanelViewController()
    private lazy var systemMenu: SystemMenu = {
        let menu = SystemMenu()
        menu.onChoose = { [weak self] item in self?.onChoose?(item) }
        menu.onClose = { [weak self] in self?.onClose?() }
        return menu
    }()
    private lazy var popup: MenuPopup = {
        let popup = MenuPopup(contentViewController: controller, takesKey: true, gap: 4, leadingOffset: -4)
        popup.onClose = { [weak self] in self?.onClose?() }
        return popup
    }()

    public override init() {
        super.init()
        controller.delegate = self
    }

    public var isShown: Bool { popup.isShown || systemMenu.isShown }

    /// Opens `content` against `control`, on `preferred` side if it fits. A
    /// menu returns once it has closed, as `NSMenu` does; a panel at once.
    public func show(_ content: MenuContent, from control: NSView, preferring preferred: MenuPopup.Side) {
        guard let window = control.window else { return }
        guard content.isPanel else {
            systemMenu.configure(with: content)
            systemMenu.popUp(from: control, on: preferred, gap: 4, leadingOffset: -4)
            return
        }
        controller.limitList(to: .greatestFiniteMagnitude)
        controller.configure(with: content)
        let anchor = window.convertToScreen(control.convert(control.bounds, to: nil))
        var size = controller.preferredSize
        let side = popup.side(for: size.height, around: anchor, preferring: preferred, in: window)
        let room = popup.room(around: anchor, in: window)
        let available = side == .above ? room.above : room.below
        if size.height > available {
            controller.limitList(to: max(Self.minimumListHeight, available - controller.chromeHeight))
            size = controller.preferredSize
        }
        popup.show(at: anchor, on: side, in: window, size: size, makingKey: true)
        controller.revealChecked()
        popup.makeFirstResponder(controller.initialFirstResponder)
    }

    /// Shows new content in the open menu, keeping its edge on the control.
    public func update(_ content: MenuContent) {
        if systemMenu.isShown {
            systemMenu.configure(with: content)
            return
        }
        controller.configure(with: content)
        guard popup.isShown else { return }
        popup.resize(to: controller.preferredSize)
    }

    public func close() {
        popup.close()
        systemMenu.close()
    }
}

extension MenuPanel: MenuPanelViewControllerDelegate {
    func menuPanelViewController(_ menuPanelViewController: MenuPanelViewController, didChoose item: MenuContent.Item) {
        if !item.keepsMenuOpen { popup.close() }
        onChoose?(item)
    }

    func menuPanelViewController(_ menuPanelViewController: MenuPanelViewController, didChangeFilter text: String) {
        onFilter?(text)
    }

    func menuPanelViewControllerDidCancel(_ menuPanelViewController: MenuPanelViewController) {
        popup.close()
    }

    func menuPanelViewControllerDidChangeSize(_ menuPanelViewController: MenuPanelViewController) {
        guard popup.isShown else { return }
        popup.resize(to: controller.preferredSize)
    }
}
