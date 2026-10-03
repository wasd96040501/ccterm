import AppKit

/// Puts a `MenuPanelViewController` on screen against the control that opens
/// it (design 08, `MENU.place`): 4 pt from the control, its leading edge 4 pt
/// before the control's, on the preferred side if it fits, else the other,
/// else the roomier one with the list shortened to fit (never under 120 pt).
/// It takes the keyboard and closes when it loses it — a click elsewhere.
///
/// Choosing an item closes it first and then reports, unless the item keeps
/// the menu open (a switch, *N More Models*): then the owner calls `update`
/// with what changed.
@MainActor
final class MenuPanel: NSObject {
    /// An item was chosen.
    var onChoose: ((MenuContent.Item) -> Void)?
    /// The filter field's words changed; the owner answers with `update`.
    var onFilter: ((String) -> Void)?
    /// The menu closed, however it closed.
    var onClose: (() -> Void)?

    /// The shortest a list is cut to when the screen has no room.
    static let minimumListHeight: CGFloat = 120

    private let controller = MenuPanelViewController()
    private lazy var popup: MenuPopup = {
        let popup = MenuPopup(contentViewController: controller, takesKey: true, gap: 4, leadingOffset: -4)
        popup.onClose = { [weak self] in self?.onClose?() }
        return popup
    }()

    override init() {
        super.init()
        controller.delegate = self
    }

    var isShown: Bool { popup.isShown }

    /// The menu's content view, for a test to find what it shows.
    var contentView: NSView { controller.view }

    /// Opens `content` against `control`, on `preferred` side if it fits.
    func show(_ content: MenuContent, from control: NSView, preferring preferred: MenuPopup.Side) {
        guard let window = control.window else { return }
        controller.listHeightLimit = .greatestFiniteMagnitude
        controller.configure(with: content)
        let anchor = window.convertToScreen(control.convert(control.bounds, to: nil))
        var size = controller.preferredSize
        let side = popup.side(for: size.height, around: anchor, preferring: preferred, in: window)
        let room = popup.room(around: anchor, in: window)
        let available = side == .above ? room.above : room.below
        if size.height > available {
            controller.listHeightLimit = max(Self.minimumListHeight, available - controller.chromeHeight)
            size = controller.preferredSize
        }
        popup.show(at: anchor, on: side, in: window, size: size, makingKey: true)
        controller.revealChecked()
        popup.makeFirstResponder(controller.initialFirstResponder)
    }

    /// Shows new content in the open menu, keeping its edge on the control.
    func update(_ content: MenuContent) {
        controller.configure(with: content)
        guard popup.isShown else { return }
        popup.resize(to: controller.preferredSize)
    }

    func close() {
        popup.close()
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
