import AppKit

/// A borderless child panel that floats over its parent window: the slash
/// list, which leaves the keyboard to the field so it keeps typing (the menus
/// are `MenuPanel`'s popovers). It sits a gap above or below an anchor
/// rectangle — the preferred side if it fits, else the other, else the
/// roomier one — 8 pt clear of the screen's edges, and follows the anchor as
/// the card moves.
///
/// Why a panel and not a subview: it pops out of the composer's card, and a
/// view outside its parent's bounds can't be clicked.
@MainActor
public final class MenuPopup: NSObject {
    public enum Side {
        case above
        case below
    }

    /// The panel closed itself (it lost the key, or `close()`).
    public var onClose: (() -> Void)?

    private(set) var side = Side.below
    private let panel: PopupPanel
    private let gap: CGFloat
    private var anchor = NSRect.zero
    private var observer: NSObjectProtocol?

    /// How far the panel keeps from the screen's edges.
    static let screenMargin: CGFloat = 8

    public var isShown: Bool { panel.isVisible }

    /// `gap` between the anchor and the panel.
    public init(contentViewController: NSViewController, takesKey: Bool, gap: CGFloat) {
        panel = PopupPanel(takesKey: takesKey)
        self.gap = gap
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
    public func show(at anchor: NSRect, preferring preferred: Side, in parent: NSWindow, size: NSSize, makingKey: Bool)
    {
        show(
            at: anchor, on: side(for: size.height, around: anchor, preferring: preferred, in: parent), in: parent,
            size: size, makingKey: makingKey)
    }

    /// Moves the panel to follow a moved or resized anchor.
    public func move(to anchor: NSRect, size: NSSize, in parent: NSWindow) {
        self.anchor = anchor
        panel.setFrame(frame(for: size, in: Self.visibleFrame(of: parent)), display: true)
        panel.invalidateShadow()
    }

    public func close() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        onClose?()
    }

    private static func visibleFrame(of parent: NSWindow) -> NSRect {
        parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
    }

    private func frame(for size: NSSize, in screen: NSRect) -> NSRect {
        let y = side == .above ? anchor.maxY + gap : anchor.minY - gap - size.height
        let margin = Self.screenMargin
        let x = max(screen.minX + margin, min(anchor.minX, screen.maxX - size.width - margin))
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
