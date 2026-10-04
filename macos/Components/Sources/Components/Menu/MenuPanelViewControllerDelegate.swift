import AppKit

/// What a menu reports. It never acts on a choice itself: the owner applies
/// it and, for an item that keeps the menu open (a switch, *N More Models*),
/// hands the menu its new content.
@MainActor
protocol MenuPanelViewControllerDelegate: AnyObject {
    /// An enabled item was clicked or taken with ↩.
    func menuPanelViewController(_ menuPanelViewController: MenuPanelViewController, didChoose item: MenuContent.Item)
    /// The filter field's words changed.
    func menuPanelViewController(_ menuPanelViewController: MenuPanelViewController, didChangeFilter text: String)
    /// ⎋.
    func menuPanelViewControllerDidCancel(_ menuPanelViewController: MenuPanelViewController)
}
