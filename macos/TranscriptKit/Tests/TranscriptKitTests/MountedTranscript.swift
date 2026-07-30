import AppKit
import TranscriptKit

/// An off-screen window with a `TranscriptView` filling it, plus the two calls
/// that make AppKit do the work it would do on screen.
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
        // A window needs the shared application to exist first; `.prohibited`
        // keeps `swift test` from putting anything in the Dock or taking focus.
        NSApplication.shared.setActivationPolicy(.prohibited)

        window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false)
        window.alphaValue = 0.01

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

        // Ordered front, not made key: an `NSTableView` off any window skips
        // work a mounted one does, and `orderFront` on a window 30 000 points
        // off-screen steals nothing.
        window.orderFront(nil)
    }

    /// Runs `passes` rounds of "flush layout, draw what needs drawing, drain the
    /// main queue".
    ///
    /// One round is enough, and that is itself the property worth noticing: the
    /// transcript's width invalidation lands *within* the pass that changed the
    /// width, so nothing is left over for a second round to settle. A change here
    /// that needs `passes: 2` has moved work onto a later tick — which is a
    /// visible frame at the old geometry, not a test detail.
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

    /// Resizes the window's content area, the way dragging its edge would —
    /// minus live resize, which no synthesized event reproduces.
    func setContentWidth(_ width: CGFloat) {
        guard let root = window.contentView else { return }
        window.setContentSize(NSSize(width: width, height: root.bounds.height))
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
