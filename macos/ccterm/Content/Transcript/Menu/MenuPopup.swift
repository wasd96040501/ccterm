import AppKit

/// A borderless child panel that floats over its parent window: every menu
/// (`MenuPanel`, which takes the keyboard) and the slash list (which doesn't —
/// the field keeps typing). It sits a gap above or below an anchor rectangle —
/// the preferred side if it fits, else the other, else the roomier one — 8 pt
/// clear of the screen's edges, and keeps the edge on the anchor where it is
/// when its height changes (design 08, `MENU.place` in preview-live.js).
///
/// Why a panel and not a subview: they pop out of the composer's card and the
/// New view, and a view outside its parent's bounds can't be clicked.
@MainActor
final class MenuPopup: NSObject {
    enum Side {
        case above
        case below
    }

    /// The panel closed itself (it lost the key, or `close()`).
    var onClose: (() -> Void)?

    private(set) var side = Side.below
    private let panel: PopupPanel
    private let gap: CGFloat
    private let leadingOffset: CGFloat
    private var anchor = NSRect.zero
    private var observer: NSObjectProtocol?

    /// How far the panel keeps from the screen's edges.
    static let screenMargin: CGFloat = 8

    var isShown: Bool { panel.isVisible }

    /// The panel's window, for asking where it is.
    var window: NSWindow { panel }

    /// `gap` between the anchor and the panel; `leadingOffset` moves the
    /// panel's leading edge from the anchor's (a menu starts 4 pt before its
    /// control, so its words line up with the control's).
    init(contentViewController: NSViewController, takesKey: Bool, gap: CGFloat, leadingOffset: CGFloat = 0) {
        panel = PopupPanel(takesKey: takesKey)
        self.gap = gap
        self.leadingOffset = leadingOffset
        super.init()
        panel.contentViewController = contentViewController
    }

    /// The room on each side of `anchor` (screen coordinates) in `parent`'s screen.
    func room(around anchor: NSRect, in parent: NSWindow) -> (above: CGFloat, below: CGFloat) {
        let screen = Self.visibleFrame(of: parent)
        return (
            screen.maxY - Self.screenMargin - (anchor.maxY + gap),
            anchor.minY - gap - (screen.minY + Self.screenMargin)
        )
    }

    /// The side a panel `height` tall goes on: `preferred` if it fits, else
    /// the other if that fits, else the roomier.
    func side(for height: CGFloat, around anchor: NSRect, preferring preferred: Side, in parent: NSWindow) -> Side {
        let room = room(around: anchor, in: parent)
        let fitsPreferred = (preferred == .above ? room.above : room.below) >= height
        let fitsOther = (preferred == .above ? room.below : room.above) >= height
        if fitsPreferred { return preferred }
        if fitsOther { return preferred == .above ? .below : .above }
        return room.above > room.below ? .above : .below
    }

    /// Shows the panel `size` big next to `anchor` (screen coordinates), on
    /// `side`.
    func show(at anchor: NSRect, on side: Side, in parent: NSWindow, size: NSSize, makingKey: Bool) {
        self.anchor = anchor
        self.side = side
        panel.setFrame(frame(for: size, in: Self.visibleFrame(of: parent)), display: false)
        if panel.parent !== parent { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
        if makingKey {
            panel.makeKey()
            if observer == nil {
                observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.close() }
                }
            }
        }
        panel.invalidateShadow()
    }

    /// Shows the panel on `preferred` side if it fits, else as `side(for:…)` says.
    func show(at anchor: NSRect, preferring preferred: Side, in parent: NSWindow, size: NSSize, makingKey: Bool) {
        show(
            at: anchor, on: side(for: size.height, around: anchor, preferring: preferred, in: parent), in: parent,
            size: size, makingKey: makingKey)
    }

    /// Moves the panel to follow a moved or resized anchor.
    func move(to anchor: NSRect, size: NSSize, in parent: NSWindow) {
        self.anchor = anchor
        panel.setFrame(frame(for: size, in: Self.visibleFrame(of: parent)), display: true)
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

    private static func visibleFrame(of parent: NSWindow) -> NSRect {
        parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
    }

    private func frame(for size: NSSize, in screen: NSRect) -> NSRect {
        let y = side == .above ? anchor.maxY + gap : anchor.minY - gap - size.height
        let margin = Self.screenMargin
        let x = max(screen.minX + margin, min(anchor.minX + leadingOffset, screen.maxX - size.width - margin))
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
