import AppKit

/// The + at the trailing end of an editor's tab bar: AppKit's accessory-bar
/// button with a plus in secondary ink, its bezel shown under the pointer and
/// darker while pressed, acting on release.
///
/// Draws only; what pressing it does is its target's.
final class NewTabButton: NSButton {
    init() {
        super.init(frame: .zero)
        title = ""
        bezelStyle = .accessoryBar
        showsBorderOnlyWhileMouseInside = true
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        contentTintColor = .secondaryLabelColor
        let name = String(localized: "New Tab", bundle: .module)
        toolTip = name + " ⌘T"
        setAccessibilityLabel(name)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("code-only")
    }
}
