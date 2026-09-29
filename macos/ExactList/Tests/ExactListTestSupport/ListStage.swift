import AppKit
import ExactList

/// A real window to mount a list in: the pattern of the app's
/// `cctermTests/Harness/AppKitStage`, which this package can't import.
///
/// By default the window is titled, at near-zero alpha. It is asked for
/// (−30 000, −30 000), but AppKit keeps a titled window on screen whatever
/// origin it is given (measured), so the window server composites it like any
/// other and presentation layers are real. A recordable stage is borderless and
/// opaque instead: AppKit leaves a borderless window where it is put, so it
/// stays off screen, and ScreenCaptureKit still captures every frame of it
/// (`WindowRecorder`). Every entry
/// point drives AppKit the way the app would: frames through the window,
/// a divider through `NSSplitView`, time through the run loop.
@MainActor
public final class ListStage {

    public let window: NSWindow

    /// The window's content view. The list, or the split holding it, goes in it.
    public var rootView: NSView { window.contentView! }

    /// The left pane's width in a split mount. A required-ish constraint the
    /// split honours over its holding priority, so moving the divider is a
    /// constraint change: animated, it lays out every frame, which is how an
    /// animated sidebar changes a pane's width.
    private var leftWidth: NSLayoutConstraint?

    /// An empty window of `size`, not yet holding anything. `recordable`
    /// makes it borderless and opaque, off screen, for `WindowRecorder`.
    public init(size: NSSize, recordable: Bool = false) {
        window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size),
            styleMask: recordable ? [.borderless] : [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if recordable {
            window.isOpaque = true
            window.hasShadow = false
            window.backgroundColor = .windowBackgroundColor
        } else {
            window.alphaValue = 0.01
        }
        window.contentView = NSView(frame: NSRect(origin: .zero, size: size))
        window.orderFrontRegardless()
    }

    /// Adds `list` to fill the window, with Auto Layout, and runs the run loop
    /// until layout settles.
    public func mount(_ list: ExactListView) async {
        await settleAppKit()
        fill(rootView, with: list)
        await settle()
    }

    /// Puts `tableView` in an `NSScrollView` configured like ExactList's own
    /// (L11), fills the window with it, and settles. It returns the scroll view.
    /// With `layOutFirst` false the table is wired and reloaded before the
    /// first layout, which is the order the §2 setup characterization needs.
    public func mountTable(_ tableView: NSTableView, layOutFirst: Bool) async -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        await settleAppKit()
        scroll.documentView = tableView
        if !layOutFirst { tableView.reloadData() }
        fill(rootView, with: scroll)
        await settle()
        if layOutFirst {
            tableView.reloadData()
            await settle()
        }
        return scroll
    }

    /// Puts `list` in the right pane of an `NSSplitView` whose left pane is
    /// `leftWidth` wide, so tests can move the divider (W1).
    public func mountInSplit(_ list: ExactListView, leftWidth: CGFloat) async {
        await settleAppKit()
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        let left = NSView()
        split.addArrangedSubview(left)
        split.addArrangedSubview(list)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow - 1, forSubviewAt: 1)
        let width = left.widthAnchor.constraint(equalToConstant: leftWidth)
        width.priority = .defaultHigh
        width.isActive = true
        self.leftWidth = width
        fill(rootView, with: split)
        await settle()
    }

    /// Moves the split's divider, animated through `animator()` or not, and
    /// returns once it has arrived.
    public func moveDivider(to position: CGFloat, animated: Bool) async {
        guard let leftWidth else { preconditionFailure("moveDivider needs mountInSplit first") }
        if animated {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    leftWidth.animator().constant = position
                } completionHandler: {
                    done.resume()
                }
            }
        } else {
            leftWidth.constant = position
        }
        await settle()
    }

    /// Resizes the window's content, as a user's resize would.
    public func setContentSize(_ size: NSSize) async {
        window.setContentSize(size)
        await settle()
    }

    /// Removes `list` from the window, keeping it alive (L8).
    public func unmount(_ list: ExactListView) {
        list.removeFromSuperview()
    }

    /// Runs the main run loop until no layout is pending and one more turn has
    /// passed.
    public func settle() async {
        for _ in 0..<3 {
            window.layoutIfNeeded()
            window.displayIfNeeded()
            await turn()
        }
        CATransaction.flush()
    }

    /// Runs the run loop until `condition` holds, or fails after `timeout`.
    public func drain(until condition: () -> Bool, timeout: TimeInterval) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() {
            if Date() > deadline { return false }
            await turn()
        }
        return true
    }

    /// Closes the window.
    public func teardown() {
        window.contentView = NSView()
        window.close()
    }

    /// Lets AppKit finish arriving at the reader's settings before anything is
    /// mounted. In a fresh process, `NSScroller.preferredScrollerStyle` answers
    /// `.overlay` until the first run loop turn has passed, then the real style
    /// (measured). A list mounted before that sees its width change under it,
    /// which is correct behaviour (§9) but not what a test means to set up.
    private func settleAppKit() async {
        guard !Self.appKitSettled else { return }
        Self.appKitSettled = true
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    /// Once per process: the transient is AppKit's launch, not the stage's.
    private static var appKitSettled = false

    /// Gives the main run loop a few milliseconds: suspending the main actor is
    /// what lets it run, from an async test.
    private func turn() async {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }

    private func fill(_ container: NSView, with view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
