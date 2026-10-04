import AppKit

/// Puts a menu on screen in a system popover (design 08 *Menus are
/// popovers*): `NSPopover`, its arrow on the control's centre, on the
/// preferred side if it fits, without animation, closing on a click outside,
/// on ⎋ and on a choice. Every pop-up of the composer and the New view —
/// Model, Effort, Permission Mode, the folder, the branch — is
/// `MenuPanelViewController` in it, taking the keyboard.
///
/// It has one size while it is open: the content's (`MenuContent.width`,
/// `listHeight`), set when it opens and never again — `update` changes what
/// the list shows, not the box, so nothing moves under the pointer.
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

    private let controller = MenuPanelViewController()
    private lazy var popover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = controller
        popover.delegate = self
        return popover
    }()

    public override init() {
        super.init()
        controller.delegate = self
    }

    public var isShown: Bool { popover.isShown }

    /// Opens `content` against `control`, on `preferred` side if it fits.
    public func show(_ content: MenuContent, from control: NSView, preferring preferred: MenuPopup.Side) {
        guard control.window != nil else { return }
        controller.configure(with: content)
        popover.contentSize = controller.preferredSize
        // The side in the control's own coordinates: max-Y is its top unless it is flipped.
        let above: NSRectEdge = control.isFlipped ? .minY : .maxY
        let below: NSRectEdge = control.isFlipped ? .maxY : .minY
        popover.show(relativeTo: control.bounds, of: control, preferredEdge: preferred == .above ? above : below)
        controller.revealChecked()
        if let window = controller.view.window {
            window.makeKey()
            window.makeFirstResponder(controller.initialFirstResponder)
        }
    }

    /// Shows new content in the open menu, in the same box.
    public func update(_ content: MenuContent) {
        controller.configure(with: content)
    }

    public func close() {
        guard popover.isShown else { return }
        popover.close()
    }
}

extension MenuPanel: NSPopoverDelegate {
    public func popoverDidClose(_ notification: Notification) {
        onClose?()
    }
}

extension MenuPanel: MenuPanelViewControllerDelegate {
    func menuPanelViewController(_ menuPanelViewController: MenuPanelViewController, didChoose item: MenuContent.Item) {
        if !item.keepsMenuOpen { close() }
        onChoose?(item)
    }

    func menuPanelViewController(_ menuPanelViewController: MenuPanelViewController, didChangeFilter text: String) {
        onFilter?(text)
    }

    func menuPanelViewControllerDidCancel(_ menuPanelViewController: MenuPanelViewController) {
        close()
    }
}
