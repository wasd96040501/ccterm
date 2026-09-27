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

        // The find bar is the toolbar's search item. Held by this scope, which
        // outlives the app: the toolbar keeps its delegate weakly.
        let toolbar = DemoToolbarController()
        window.toolbar = toolbar.toolbar
        window.toolbarStyle = .unified
        // After the toolbar exists, because the Find items target it. Copy still
        // targets nothing and walks the chain — see below.
        app.mainMenu = makeMainMenu(find: toolbar)

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
        panel.onStream = { host.toggleStreaming(row: $0) }
        panel.onColdLoad = { rows, prepared in host.coldLoad(rows: rows, prepared: prepared) }
        panel.onCancelColdLoad = { host.cancelColdLoad() }
        panel.onMaxContentWidth = { transcript.maxContentWidth = $0 }
        toolbar.onFind = { transcript.find($0) }
        toolbar.onFindNext = { transcript.findNext() }
        toolbar.onFindPrevious = { transcript.findPrevious() }
        host.onFindChange = { matches, isComplete in
            // Only a finished walk is shown. A count climbing under the typing is
            // noise, and a resumed walk — a row streamed in, a row appended —
            // reports incomplete for a moment before settling where it was.
            guard isComplete else { return }
            toolbar.setFindCount(selected: transcript.indexOfSelectedFindMatch, of: matches)
        }
        host.onRowCountChange = { panel.setStatus("\($0) rows") }
        host.onStreamingChange = { panel.setStreaming($0) }
        host.onColdLoadProgress = { panel.setColdLoadStatus($0) }

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
        // How much distinct material is behind a cold load, so the row count
        // asked for can be read against how often the corpus repeats.
        panel.setColdLoadStatus("\(StressCorpus.sectionCount) distinct documents")

        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }

    /// The Edit menu is not decoration here — it is the **only** thing that makes
    /// ⌘C work, and its absence is what this demo was quietly missing.
    ///
    /// A key equivalent is not delivered to the first responder the way a
    /// keystroke is. `NSApplication` hands the event to the key window and then
    /// to the main menu; the Copy item, carrying action `copy:` and a `nil`
    /// target, is what turns it into a responder-chain dispatch that reaches the
    /// selected row. With no main menu there is no such item, so the chain is
    /// never walked and `BlockView.copy(_:)` is never called — which looks
    /// exactly like the transcript not implementing copy at all.
    ///
    /// Worth stating plainly because it is also the demo's job to show that the
    /// package needs *no* wiring for this: an app that has a normal Edit menu
    /// (any nib-based app, and any SwiftUI shell) gets ⌘C for free.
    @MainActor
    private static func makeMainMenu(find toolbar: DemoToolbarController) -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit \(ProcessInfo.processInfo.processName)",
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        // `nil` target, so this dispatches down the responder chain rather than
        // to any particular object — which is the whole mechanism.
        editMenu.addItem(
            withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")

        // These three do have a target, unlike Copy above, and the difference is
        // which object knows the answer. Copy belongs to whichever row holds the
        // selection, which only the responder chain can find; a find belongs to the
        // one find bar in the window, which is right here. Routing them down the
        // chain instead would mean the transcript growing a `performFindPanelAction`
        // — AppKit's hook for a find bar the *view* owns — and this one is the
        // host's, which is the arrangement §4 is about.
        editMenu.addItem(.separator())
        for (title, key, action) in [
            ("Find…", "f", #selector(DemoToolbarController.beginFind)),
            ("Find Next", "g", #selector(DemoToolbarController.findNext)),
            ("Find Previous", "G", #selector(DemoToolbarController.findPrevious)),
        ] {
            let item = editMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = toolbar
        }

        editItem.submenu = editMenu
        main.addItem(editItem)

        return main
    }
}
