import AppKit

@testable import ccterm

/// Offscreen-mounted transcript for Tier-2 measurement probes. Drives the
/// **exact** production attach sequence —
/// `TranscriptScrollViewFactory.make` → `addSubview` + constraints → host
/// `layoutSubtreeIfNeeded` → `factory.bindData` → `controller.scrollToTail()` —
/// inside an `alphaValue = 0.01` window, so the table reaches its real width
/// and `heightOfRow` queries fire at the settled width (the same scaffold
/// `TranscriptReentryLayoutCacheTests` uses). Mirrors `TranscriptScrollView`
/// geometry without the full `TranscriptDetailViewController`.
@MainActor
struct MountedTranscript {
    let window: NSWindow
    let container: NSView
    let scroll: Transcript2ScrollView
    let controller: Transcript2Controller

    static let defaultSize = CGSize(width: 720, height: 800)

    var table: NSTableView { scroll.documentView as! NSTableView }
    var clip: NSClipView { scroll.contentView }

    /// Mount `controller`'s scroll view in a fresh offscreen window, running
    /// the production attach order. After this returns the table is bound and
    /// `layoutWidth` is the settled clamped width.
    static func mount(
        controller: Transcript2Controller,
        size: CGSize = defaultSize
    ) -> MountedTranscript {
        let scroll = TranscriptScrollViewFactory.make(controller: controller)

        let window = NSWindow(
            contentRect: NSRect(
                origin: CGPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
        window.ccterm_orderFrontForTesting()

        // Settle geometry before binding the dataSource (the §2.19 contract:
        // an unbound shell sizes without firing heightOfRow at transient
        // widths), then bind + anchor at the tail.
        container.layoutSubtreeIfNeeded()
        TranscriptScrollViewFactory.bindData(scroll, controller: controller)
        controller.scrollToTail()

        return MountedTranscript(
            window: window, container: container, scroll: scroll,
            controller: controller)
    }

    func teardown() {
        TranscriptScrollViewFactory.dismantle(scroll, controller: controller)
        window.contentView = nil
        window.close()
    }

    // MARK: - Geometry sampling

    /// Row index of the topmost row currently visible in the clip, or `nil`
    /// when nothing is laid out.
    var visualTopRow: Int? {
        let visible = table.rows(in: table.visibleRect)
        guard visible.location != NSNotFound, visible.length > 0 else { return nil }
        return visible.location
    }

    /// On-screen Y of a row's top edge, measured from the top of the viewport
    /// (the table is flipped, so this is `rect.origin.y - clip.bounds.origin.y`).
    /// This is the quantity a prepend with `.saveVisible(.visualTop)` must keep
    /// fixed for the anchor row.
    func onScreenTop(ofRow row: Int) -> CGFloat {
        table.rect(ofRow: row).origin.y - clip.bounds.origin.y
    }

    /// Drain the runloop for `seconds` so deposited backfill pages flush and
    /// any deferred autolayout / tile work settles.
    func drain(seconds: TimeInterval = 0.05) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
    }
}
