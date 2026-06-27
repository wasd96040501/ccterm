import AppKit
import SwiftUI

/// AppKit container that mounts the SwiftUI `ArchiveView` as the
/// detail pane's content when the sidebar selection is `.archive`.
/// Owned by `DetailRouterViewController`; lives only while archive
/// is selected and is fully torn down on selection change (no
/// lingering subviews, no observation tasks left armed).
///
/// Mounted via `mountFillPaneHost(_:in:)` (regime-A: `NSHostingController`
/// + `sizingOptions = []` + four-edge pin) so the SwiftUI tree is hosted
/// with proper child-VC plumbing — `NSHostingController` forwards
/// `viewDidLoad` / `viewWillAppear` / etc. into the SwiftUI runtime, which
/// `NSHostingView` alone does not — and its fitting size can't leak up
/// through the split and collapse the window. See the helper for the full
/// rationale.
@MainActor
final class ArchiveViewController: NSViewController {
    /// `nonisolated` so dealloc skips the `@MainActor` deinit executor-hop
    /// that aborts in the XCTest process (macOS 26 libswift_Concurrency
    /// `TaskLocal` teardown bug). See `SessionRuntime.swift`.
    nonisolated deinit {}

    /// The detail-scope dependency bag, handed down from the router.
    /// `model` and the four injected services are read through this.
    let context: DetailContext

    /// The mounted host. Typed as `NSViewController` because
    /// `mountFillPaneHost` returns an `NSHostingController<Content>` whose
    /// `Content` is a long `ModifiedContent` generic — storing it at the
    /// `NSViewController` supertype keeps the property declarable without
    /// spelling that type out. Retained so the host outlives `viewDidLoad`.
    private var host: NSViewController?

    init(context: DetailContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // `model.archiveSelectedFolderPath` is the source of truth —
        // the toolbar's folder-filter button writes to the same field,
        // so a two-way binding keeps the popover and the list in sync.
        let folderBinding = Binding<String?>(
            get: { [weak self] in self?.context.model.archiveSelectedFolderPath },
            set: { [weak self] in self?.context.model.archiveSelectedFolderPath = $0 }
        )

        // Fill-the-pane detail child: `mountFillPaneHost` clears
        // `sizingOptions` (regime-A) so `ArchiveView`'s `ScrollView` fitting
        // height — just the header (~176pt before the async list lands) —
        // can't bubble up through the detail VC → the split's
        // `view.fittingSize` and collapse the whole window down to it the
        // instant Archive is selected. The four-edge pin inside the helper
        // makes the pane take whatever height the window gives it instead of
        // driving it. Confirmed offscreen: with the default options
        // `host.view.fittingSize` ≈ 545×276; cleared, it's 0×0 and the split
        // fills the window.
        host = mountFillPaneHost(
            ArchiveView(
                selectedFolderPath: folderBinding,
                onUnarchive: { [weak self] resumeSid in
                    self?.context.model.select(.session(resumeSid))
                }
            )
            .injectDetailEnvironment(context),
            in: self
        )
    }
}
