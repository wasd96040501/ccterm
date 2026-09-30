import AppKit
import XCTest

@testable import TranscriptKit

/// A `TestWindow` with a `TranscriptView` filling it, plus the two calls that
/// make AppKit do the work it would do on screen.
///
/// **Deliberately without logic.** Build a window, mount, flush layout, drain
/// the runloop — no branches, no derived numbers, no helper that computes what a
/// test ought to expect. Every expected value is written in the test that
/// asserts it. A harness with nothing to get wrong needs no verification of its
/// own, which is cheaper than verifying one that does.
///
/// What this can and cannot see: the window never becomes key, so anything
/// gated on key-window or first-responder state (tracking areas, focus ring,
/// cursor rects) is out of reach. Geometry, row bookkeeping, and how many times
/// the transcript asked its delegate for what are all in reach, and that is what
/// this package's tests are about.
@MainActor
final class MountedTranscript {

    let window: NSWindow
    let transcript = TranscriptView()

    init(size: NSSize) {
        window = TestWindow.make(contentSize: size)

        let root = NSView()
        window.contentView = root
        transcript.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(transcript)
        NSLayoutConstraint.activate([
            transcript.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            transcript.topAnchor.constraint(equalTo: root.topAnchor),
            transcript.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    /// Runs `passes` rounds of "flush layout, draw what needs drawing, drain the
    /// main queue".
    ///
    /// One round is enough for everything the transcript does *inside* the pass
    /// that provoked it, which is everything except one thing: a width change
    /// leaves the rows off screen to later turns, so a test that changed the
    /// width and wants the whole transcript settled uses `settleWidthChange()`
    /// instead. Reaching for
    /// `passes: 2` anywhere else means work moved onto a later tick — a visible
    /// frame at the old geometry, not a test detail.
    ///
    /// A parameter rather than a loop-until-quiet so the count stays at the call
    /// site instead of hiding in here.
    func settle(passes: Int = 1) {
        for _ in 0..<passes {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0))
        }
    }

    /// Settles, then waits for the off-main re-measure a width change starts, then
    /// gives the list the idle turns it refreshes stale rows on.
    ///
    /// The `Task` is ordinary production state — the transcript holds it to cancel
    /// a superseded run — so this waits on the real thing rather than polling or
    /// sleeping, and there is no seam here that exists for the test.
    ///
    /// One turn per row, plus one, because that is the bound the list promises:
    /// every idle turn refreshes at least one stale row (ExactList W5). A test
    /// that wants to look *during* the window calls `settle()` and not this.
    func settleWidthChange() async {
        settle()
        await transcript.remeasuring?.value
        settle(passes: transcript.numberOfRows + 1)
    }

    /// Settles, then waits for the walk `find(_:)` starts, then settles again.
    ///
    /// The sibling of `settleWidthChange()` above, waiting on the same kind of
    /// ordinary production state for the same reason: a find publishes across
    /// several turns, and the only honest way to know they have all landed is to
    /// wait for the thing that publishes them.
    func settleFind() async {
        settle()
        await transcript.finding?.value
        settle()
    }

    /// Resizes the window's content area, the way dragging its edge would —
    /// minus live resize, which no synthesized event reproduces.
    func setContentWidth(_ width: CGFloat) {
        guard let root = window.contentView else { return }
        window.setContentSize(NSSize(width: width, height: root.bounds.height))
    }

    /// The transcript's scroll view, found in the mounted tree.
    ///
    /// A lookup, not logic. The transcript keeps its scroller to itself, and a
    /// test asking "where is the viewport" has nowhere to read that but AppKit's
    /// own public surface — `documentVisibleRect` and the clip's bounds. Which is
    /// the better place to read it anyway: those are the numbers the window
    /// draws from, not a second opinion the transcript publishes.
    var scrollView: NSScrollView {
        transcript.descendants(ofType: NSScrollView.self)[0]
    }

    /// Scrolls the way a wheel or a drag would, neither of which can be
    /// synthesized into a window that is never key.
    func scroll(toY y: CGFloat) {
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    /// A press on `view`, and the rest of its gesture — `rest`, then a release —
    /// queued first, the way the window server has them waiting behind the press.
    ///
    /// Queued rather than sent, because a press that selects is tracked to its
    /// release inside `mouseDown`, by a loop that *pulls* the events after it. The
    /// release is always there, so a test cannot leave a loop waiting.
    ///
    /// And the queue is the application's, not this window's, so a gesture that
    /// was not tracked would stay in it and be pulled by the next test's press —
    /// which then selects with another test's pointer. So the press asserts that
    /// its gesture was used up, which is where such a failure has to be named.
    /// Row `row`'s rectangle in the scrolled document, the space an offset is
    /// measured in: `rect(ofRow:)` with the scroll offset taken back out.
    func documentRect(ofRow row: Int) -> NSRect {
        transcript.rect(ofRow: row).offsetBy(dx: 0, dy: scrollView.contentView.bounds.minY)
    }

    func press(
        _ view: NSView, with down: NSEvent, then rest: [NSEvent] = [],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: down.locationInWindow, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: down.clickCount, pressure: 0)!
        for event in rest + [up] { NSApp.postEvent(event, atStart: false) }
        view.mouseDown(with: down)
        let left = NSApp.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp, .periodic, .scrollWheel],
            until: .distantPast, inMode: .default, dequeue: true)
        XCTAssertNil(left, "the press was not tracked to its release", file: file, line: line)
    }

    /// What Edit ▸ Copy puts on the pasteboard: the action sent up the responder
    /// chain from the window's first responder, which is where a menu item with a
    /// `nil` target starts. `NSApp.sendAction` would start from the *key* window,
    /// and this one never is.
    ///
    /// Cleared first, because a copy with nothing selected writes nothing — without
    /// the clear, "nothing was copied" and "the last copy is still there" read the
    /// same.
    func copy() -> String? {
        NSPasteboard.general.clearContents()
        window.firstResponder?.tryToPerform(#selector(NSText.copy(_:)), with: nil)
        return NSPasteboard.general.string(forType: .string)
    }

    /// Whether Edit ▸ Copy would be enabled: the first responder that answers
    /// `copy(_:)`, asked the way AppKit asks it.
    var canCopy: Bool {
        let item = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        // The responder that answers is found the way AppKit finds a nil-targeted
        // action's: up the chain from the first responder.
        var responder = window.firstResponder
        while let current = responder, !current.responds(to: item.action) { responder = current.nextResponder }
        guard let responder else { return false }
        return (responder as? NSUserInterfaceValidations)?.validateUserInterfaceItem(item) ?? true
    }

    func teardown() {
        window.orderOut(nil)
        window.contentView = nil
    }
}

extension NSView {

    /// Every descendant of type `V`, in tree order.
    func descendants<V: NSView>(ofType type: V.Type) -> [V] {
        var found: [V] = []
        for subview in subviews {
            if let match = subview as? V { found.append(match) }
            found.append(contentsOf: subview.descendants(ofType: type))
        }
        return found
    }
}
