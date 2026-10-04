import AppKit

extension NSButton {
    /// A button that opens a `MenuPopover` (design 08 *Menus are popovers*):
    /// the system's accessory-bar button, its bezel showing under the pointer,
    /// darker while pressed and on while its popover is open; it acts on
    /// press, as a menu's button does. A chevron follows the title; the title
    /// and the tint are the owner's.
    package static func menuButton() -> NSButton {
        let button = NSButton(title: "", target: nil, action: nil)
        button.bezelStyle = .accessoryBar
        button.setButtonType(.pushOnPushOff)
        button.showsBorderOnlyWhileMouseInside = true
        button.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        button.imagePosition = .imageTrailing
        button.sendAction(on: [.leftMouseDown])
        button.setAccessibilityRole(.popUpButton)
        return button
    }
}
