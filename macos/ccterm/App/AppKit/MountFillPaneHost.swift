import AppKit
import SwiftUI

/// Mount `rootView` as `container`'s fill-the-pane content via an
/// `NSHostingController`, wired with proper child-VC plumbing and pinned
/// edge-to-edge. The single home for the **regime-A** hosting recipe that
/// `ArchiveViewController` / `ComposeSessionViewController` /
/// `DraftSessionLandingViewController` each used to hand-roll verbatim.
///
/// The recipe, and why each step:
///
/// - **`NSHostingController` (not a bare `NSHostingView`)** so the SwiftUI
///   tree gets `viewDidLoad` / `viewWillAppear` / etc. forwarded into the
///   SwiftUI runtime — `NSHostingView` alone does not.
/// - **`sizingOptions = []`** — this is what makes it regime-A. The default
///   options publish the SwiftUI body's `view.fittingSize` as an intrinsic
///   size; for a fill-the-pane child whose content has a small fitting
///   height (e.g. `ArchiveView`'s `ScrollView` header, the compose card),
///   that height leaks up through the split's `view.fittingSize` into the
///   window's constraint solver and collapses the window. `[]` severs that
///   path; the four-edge pin below then lets layout size the host *from the
///   container*, which is what a pane host wants — the container (split →
///   window) drives the size, never the reverse.
/// - **`addChild` + four-edge pin** so containment is correct and the host
///   fills the container.
///
/// This is the FILL-A-PANE host shape. A subordinate component (the chat
/// resting bar, a toolbar slot) is regime-B — `sizingOptions =
/// [.intrinsicContentSize]` + position-only constraints — and deliberately
/// does NOT route through here; its container is sized by something else and
/// it *wants* the content to drive its own size. See `CLAUDE.md` §
/// "Embedding SwiftUI in AppKit: host sizing" and
/// `ChatSessionViewController.restingBarHost`.
@MainActor
@discardableResult
func mountFillPaneHost<Content: View>(
    _ rootView: Content,
    in container: NSViewController
) -> NSHostingController<Content> {
    let host = NSHostingController(rootView: rootView)
    host.sizingOptions = []
    container.addChild(host)
    host.view.translatesAutoresizingMaskIntoConstraints = false
    container.view.addSubview(host.view)
    NSLayoutConstraint.activate([
        host.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
        host.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
        host.view.topAnchor.constraint(equalTo: container.view.topAnchor),
        host.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor),
    ])
    return host
}
