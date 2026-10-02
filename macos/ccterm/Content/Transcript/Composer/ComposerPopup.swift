import AppKit

/// A borderless child panel that floats over the composer's window: the model
/// panel (it takes the keyboard) and the slash list (it doesn't — the field
/// keeps typing). It sits a gap above or below an anchor rectangle, on the
/// side with room, and keeps that edge where it is when its height changes.
///
/// Why a panel and not a subview: both pop out of the composer's card, and a
/// view outside its parent's bounds can't be clicked.
@MainActor
final class ComposerPopup: NSObject {
    enum Side {
        case above
        case below
    }

    /// The panel closed itself (it lost the key, or `close()`).
    var onClose: (() -> Void)?

    private(set) var side = Side.below
    private let panel: PopupPanel
    private let gap: CGFloat
    private var anchor = NSRect.zero
    private var observer: NSObjectProtocol?

    var isShown: Bool { panel.isVisible }

    /// The panel's window, for asking where it is.
    var window: NSWindow { panel }

    init(contentViewController: NSViewController, takesKey: Bool, gap: CGFloat) {
        panel = PopupPanel(takesKey: takesKey)
        self.gap = gap
        super.init()
        panel.contentViewController = contentViewController
    }

    /// Shows the panel `size` big next to `anchor` (screen coordinates), on
    /// `preferred` side if it fits, else the other.
    func show(at anchor: NSRect, preferring preferred: Side, in parent: NSWindow, size: NSSize, makingKey: Bool) {
        self.anchor = anchor
        let screen = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let roomAbove = screen.maxY - anchor.maxY - gap
        let roomBelow = anchor.minY - gap - screen.minY
        let fitsPreferred = (preferred == .above ? roomAbove : roomBelow) >= size.height
        let fitsOther = (preferred == .above ? roomBelow : roomAbove) >= size.height
        if fitsPreferred {
            side = preferred
        } else if fitsOther {
            side = preferred == .above ? .below : .above
        } else {
            side = roomAbove > roomBelow ? .above : .below
        }
        panel.setFrame(frame(for: size, in: screen), display: false)
        if panel.parent !== parent { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
        if makingKey {
            panel.makeKey()
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        }
        panel.invalidateShadow()
    }

    /// Moves the panel to follow a moved or resized anchor.
    func move(to anchor: NSRect, size: NSSize, in parent: NSWindow) {
        self.anchor = anchor
        let screen = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        panel.setFrame(frame(for: size, in: screen), display: true)
        panel.invalidateShadow()
    }

    /// Resizes keeping the edge on the anchor where it is.
    func resize(to size: NSSize) {
        var frame = panel.frame
        let delta = size.height - frame.height
        if side == .below { frame.origin.y -= delta }
        frame.size = size
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    func close() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        onClose?()
    }

    /// The keyboard goes to `view`.
    func makeFirstResponder(_ view: NSView) {
        panel.makeFirstResponder(view)
    }

    private func frame(for size: NSSize, in screen: NSRect) -> NSRect {
        let y = side == .above ? anchor.maxY + gap : anchor.minY - gap - size.height
        let x = min(max(anchor.minX, screen.minX + 8), max(screen.minX + 8, screen.maxX - size.width - 8))
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// Borderless and clear, so the content's rounded shape is the panel's.
private final class PopupPanel: NSPanel {
    private let takesKey: Bool

    init(takesKey: Bool) {
        self.takesKey = takesKey
        super.init(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        becomesKeyOnlyIfNeeded = !takesKey
    }

    override var canBecomeKey: Bool { takesKey }
    override var canBecomeMain: Bool { false }
}
