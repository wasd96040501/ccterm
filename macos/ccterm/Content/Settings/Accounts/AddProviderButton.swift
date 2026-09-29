import AppKit

/// Add Provider… as a split button: the button adds a blank provider, its
/// menu imports one from the clipboard — the same as ⌘V on the pane.
/// Import is enabled only while the clipboard holds something to fill a
/// provider from.
@MainActor
final class AddProviderButton: NSComboButton, NSMenuItemValidation {
    /// Add Provider… was clicked.
    var onAdd: (() -> Void)?
    /// Import from Clipboard was chosen.
    var onImport: (() -> Void)?

    init() {
        super.init(frame: .zero)
        title = String(localized: "Add Provider…")
        style = .split
        target = self
        action = #selector(add(_:))
        let item = NSMenuItem(
            title: String(localized: "Import from Clipboard"), action: #selector(importFromClipboard(_:)),
            keyEquivalent: "v")
        item.target = self
        menu = NSMenu()
        menu.addItem(item)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func add(_ sender: Any?) {
        onAdd?()
    }

    @objc private func importFromClipboard(_ sender: Any?) {
        onImport?()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(importFromClipboard(_:)) else { return true }
        return NSPasteboard.general.string(forType: .string).flatMap(AccountPaste.init) != nil
    }
}
