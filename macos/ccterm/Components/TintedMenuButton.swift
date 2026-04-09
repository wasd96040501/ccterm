import SwiftUI
import AppKit

struct TintedMenuItem {
    let id: String
    let icon: String          // SF Symbol name
    let title: String
    let subtitle: String?     // optional, shows second line when present
    let tintColor: NSColor
    let isSelected: Bool
    var customImage: NSImage? = nil  // overrides SF Symbol icon when set
}

struct TintedMenuButton<Label: View>: View {
    let items: [TintedMenuItem]
    let onSelect: (String) -> Void
    @ViewBuilder let label: () -> Label

    @State private var anchorView: NSView?

    /// Wraps the styled button. Callers provide this via the initializers below.
    private let styledButton: (Button<Label>, Binding<NSView?>) -> AnyView

    var body: some View {
        styledButton(Button(action: showMenu) { label() }, $anchorView)
    }

    private func showMenu() {
        guard let anchor = anchorView else { return }

        let menu = NSMenu()
        let coordinator = MenuCoordinator(onSelect: onSelect)

        let iconConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)

        for item in items {
            let menuItem = NSMenuItem()
            let tint = item.tintColor
            if let custom = item.customImage {
                menuItem.image = custom
            } else {
                let colorConfig = NSImage.SymbolConfiguration(paletteColors: [tint])
                let icon = NSImage(systemSymbolName: item.icon, accessibilityDescription: item.title)?
                    .withSymbolConfiguration(iconConfig.applying(colorConfig))
                menuItem.image = icon
            }

            let titleString = NSMutableAttributedString()
            titleString.append(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 4)]))
            titleString.append(NSAttributedString(string: item.title, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
                .foregroundColor: tint,
            ]))
            if let subtitle = item.subtitle {
                titleString.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 2)]))
                titleString.append(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 4)]))
                let subtitleColor = (tint == .labelColor) ? NSColor.secondaryLabelColor : tint
                titleString.append(NSAttributedString(string: subtitle, attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: subtitleColor,
                ]))
            }
            menuItem.attributedTitle = titleString
            menuItem.state = item.isSelected ? .on : .off
            menuItem.representedObject = item.id
            menuItem.target = coordinator
            menuItem.action = #selector(MenuCoordinator.menuItemSelected(_:))
            menu.addItem(menuItem)
        }

        // popUp is synchronous — coordinator stays alive as local variable.
        // Dispatch onSelect asynchronously so SwiftUI animation transactions
        // work correctly after the blocking popUp returns.
        let originalOnSelect = coordinator.onSelect
        coordinator.onSelect = { id in
            DispatchQueue.main.async { originalOnSelect(id) }
        }
        let point = NSPoint(x: 0, y: anchor.bounds.height + 4)
        menu.popUp(positioning: nil, at: point, in: anchor)
    }
}

// MARK: - Default HoverCapsuleStyle

extension TintedMenuButton {
    init(
        items: [TintedMenuItem],
        onSelect: @escaping (String) -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.items = items
        self.onSelect = onSelect
        self.label = label
        self.styledButton = { button, anchorView in
            AnyView(
                button
                    .buttonStyle(HoverCapsuleStyle())
                    .background(MenuAnchorRepresentable(anchorView: anchorView))
            )
        }
    }
}

// MARK: - Custom ButtonStyle

extension TintedMenuButton {
    init<S: ButtonStyle>(
        items: [TintedMenuItem],
        onSelect: @escaping (String) -> Void,
        buttonStyle: S,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.items = items
        self.onSelect = onSelect
        self.label = label
        self.styledButton = { button, anchorView in
            AnyView(
                button
                    .buttonStyle(buttonStyle)
                    .background(MenuAnchorRepresentable(anchorView: anchorView))
            )
        }
    }
}

// MARK: - Custom PrimitiveButtonStyle

extension TintedMenuButton {
    init<S: PrimitiveButtonStyle>(
        items: [TintedMenuItem],
        onSelect: @escaping (String) -> Void,
        buttonStyle: S,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.items = items
        self.onSelect = onSelect
        self.label = label
        self.styledButton = { button, anchorView in
            AnyView(
                button
                    .buttonStyle(buttonStyle)
                    .background(MenuAnchorRepresentable(anchorView: anchorView))
            )
        }
    }
}

// MARK: - Menu Action Coordinator

private class MenuCoordinator: NSObject {
    var onSelect: (String) -> Void
    init(onSelect: @escaping (String) -> Void) { self.onSelect = onSelect }

    @objc func menuItemSelected(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onSelect(id)
    }
}

// MARK: - NSView Anchor

private struct MenuAnchorRepresentable: NSViewRepresentable {
    @Binding var anchorView: NSView?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            anchorView = nsView
        }
    }
}
