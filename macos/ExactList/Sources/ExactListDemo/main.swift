import AppKit

// `swift run ExactListDemo` (make demo-list). The checklist it serves is in
// CLAUDE.md next to this file.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = DemoAppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
