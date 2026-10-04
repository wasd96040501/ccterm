import AppKit

/// A menu shown still (`.lv-menu.static`): its `NSMenu`'s own item views,
/// stacked as the menu stacks them under its padding (the system's, the
/// design's 5) — what it draws open, which an off-screen page can't capture
/// while it tracks. The views leave their items — the menu, asked its size
/// again, would lay them out in its own window — so it is shown, never popped.
final class StaticMenuView: NSView {
    init(_ menu: NSMenu) {
        let size = menu.size
        super.init(frame: NSRect(origin: .zero, size: size))
        let rows = menu.items.compactMap(\.view).reduce(0) { $0 + $1.frame.height }
        var y = ((size.height - rows) / 2).rounded()
        for item in menu.items {
            guard let view = item.view else { continue }
            item.view = nil
            view.frame.origin = NSPoint(x: 0, y: y)
            addSubview(view)
            y += view.frame.height
        }
    }

    override var isFlipped: Bool { true }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}
