import AppKit

/// The label the demo puts under the pointer to show where a link goes.
///
/// **Host code, deliberately.** `TranscriptKit` reports which link the pointer is
/// on (`transcriptView(_:didHover:at:inRow:)`) and draws none of this: what the
/// label looks like, whether it follows the pointer, how long it lingers, whether
/// it appears at all — all product decisions, and a panel built into the package
/// would be it growing chrome it has no business owning. A real app would style
/// this differently, or put the address in a status bar instead, without the
/// transcript knowing.
///
/// **Not `NSView.addToolTip` either.** AppKit's tooltip waits out a system delay
/// measured in seconds before showing anything, and the delay is the tooltip
/// manager's with no public way to shorten it. Reading is a scanning motion, so
/// the answer has to arrive at the speed of the pointer; this shows on the move
/// that lands on the link.
///
/// It never takes the pointer (`ignoresMouseEvents`) and never takes focus
/// (`orderFront`, never `makeKey`) — either would end the hover that summoned it.
final class LinkTooltip {

    /// Room left for the pointer itself, so the label clears the pointing hand.
    private let cursorClearance: CGFloat = 20

    private let padding = CGSize(width: 7, height: 4)

    private lazy var label: NSTextField = {
        let label = NSTextField(labelWithString: "")
        // The size AppKit's own tooltip uses. Below body size on purpose: this is
        // annotation, and should not compete with the sentence it explains.
        label.font = .systemFont(ofSize: 11)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 1
        // A URL's meaning is at both ends — the host and the leaf — so a long one
        // loses its middle rather than its tail.
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }()

    private lazy var window: NSWindow = {
        let window = NSWindow(
            contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        // Above the transcript and its scrollers, below a menu the reader opened.
        window.level = .popUpMenu
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        window.animationBehavior = .none

        let effect = NSVisualEffectView()
        // The material AppKit dresses its own tooltips in, so this reads as the
        // system's affordance rather than as something invented here.
        effect.material = .toolTip
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 5
        effect.layer?.masksToBounds = true

        label.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: padding.width),
            label.trailingAnchor.constraint(
                equalTo: effect.trailingAnchor, constant: -padding.width),
            label.topAnchor.constraint(equalTo: effect.topAnchor, constant: padding.height),
            label.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -padding.height),
        ])

        window.contentView = effect
        return window
    }()

    private var isShowing = false

    /// Puts `text` below the pointer, which is at `point` in `view`'s coordinates.
    ///
    /// The transcript reports hovers on change only, so this is called once per
    /// link rather than once per mouse-moved event — which is also why the label
    /// stays where it appeared instead of chasing the pointer along a word.
    func show(_ text: String, at point: NSPoint, in view: NSView) {
        guard !text.isEmpty, let host = view.window else { return hide() }

        label.stringValue = text
        // Wide enough for a long URL to stay useful, narrow enough that it cannot
        // become a paragraph — past this the middle is dropped instead.
        let width = min(label.fittingSize.width, 480) + padding.width * 2
        let size = CGSize(width: width, height: label.fittingSize.height + padding.height * 2)

        let onScreen = host.convertPoint(toScreen: view.convert(point, to: nil))
        window.setFrame(placed(size, below: onScreen, on: host.screen), display: true)
        window.orderFront(nil)
        isShowing = true
    }

    func hide() {
        guard isShowing else { return }
        isShowing = false
        window.orderOut(nil)
    }

    /// Below the pointer, nudged back onto the screen if that would hang it off an
    /// edge — and flipped above the pointer when there is no room below, which is
    /// what happens hovering the last line of a window at the bottom of a display.
    private func placed(_ size: CGSize, below point: NSPoint, on screen: NSScreen?) -> NSRect {
        var origin = NSPoint(x: point.x, y: point.y - cursorClearance - size.height)

        if let visible = screen?.visibleFrame {
            if origin.y < visible.minY {
                origin.y = point.y + cursorClearance / 2
            }
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        return NSRect(origin: origin, size: size)
    }
}
