import AppKit
import TranscriptKit

/// A window with a `TranscriptView` in it: assistant turns as `.markdown`,
/// user turns as host-drawn `.view` bubbles. Run with `make demo-kit`.
///
/// What it is for: the things a probe can't tell you. Read the seven documents
/// in `DemoMessage.script` and check that they look like documents — that is the
/// only test markdown rendering really has. Then drag the window across the
/// content width clamp, and use the panel to mutate rows above the viewport and
/// watch that the text under your eyes doesn't move, which is the one property
/// the tests can assert but not convince anyone of.
@main
struct Demo {

    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "TranscriptKit"
        // Narrower than any real host would allow, on purpose: reflow, column
        // collapse and min-content wrapping are all things you have to squeeze
        // the window to see.
        window.contentMinSize = NSSize(width: 100, height: 200)

        let host = DemoHost()
        let root = NSView()
        window.contentView = root

        let transcript = TranscriptView()
        transcript.translatesAutoresizingMaskIntoConstraints = false
        transcript.dataSource = host
        transcript.delegate = host
        // Host policy: content stops widening at a readable measure and the
        // window keeps the rest as margin.
        transcript.maxContentWidth = 720
        host.transcript = transcript

        let panel = ControlPanelView()
        panel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(transcript)
        root.addSubview(panel)
        NSLayoutConstraint.activate([
            transcript.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            transcript.topAnchor.constraint(equalTo: root.topAnchor),
            // The full height, chrome included: the panel is something rows scroll
            // under, not something that takes their space away.
            transcript.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            panel.heightAnchor.constraint(equalToConstant: ControlPanelView.height),
        ])

        // The inset the panel earns: the last row comes to rest above the blur
        // rather than behind it. Written by the host, from a height the host knows
        // — nothing in the transcript watches for chrome.
        transcript.contentInsets = NSEdgeInsets(
            top: 12, left: 0, bottom: ControlPanelView.height + 12, right: 0)

        panel.onScrollToRow = { row, position in
            transcript.scrollToRow(at: row, scrollPosition: position)
        }
        panel.onPrepend = { host.prepend(5) }
        panel.onAppend = { host.append() }
        panel.onRemoveTop = { host.removeTop(3) }
        panel.onGrowFirst = { host.growFirstRow() }
        panel.onRemeasureFirst = { host.remeasureFirstRow() }
        panel.onBatch = { host.prependAndRemoveInOneBatch() }
        panel.onMaxContentWidth = { transcript.maxContentWidth = $0 }
        host.onRowCountChange = { panel.setStatus("\($0) rows") }

        // Lay the tree out before loading, so the table's first — and only —
        // measurement pass runs at the settled content width. Loading first
        // measures every row twice: once at the width the transcript has before
        // Auto Layout has run (zero), then again once it has a real one, and the
        // correcting pass is a full-table `noteHeightOfRows`, which AppKit
        // animates. The first screen then arrives and visibly settles.
        //
        // `NSTableView` behaves the same way for the same reason, so this is the
        // host's job rather than something the transcript could take over: mount,
        // lay out, then load.
        root.layoutSubtreeIfNeeded()
        transcript.reloadData()
        panel.setStatus("\(transcript.numberOfRows) rows")

        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}
