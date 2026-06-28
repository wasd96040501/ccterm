import AppKit

/// Owned image-preview presenter for the input bar (migration plan §4.7-1,
/// R5). Mirrors `Transcript2SheetPresenter`'s ownership shape — but driven
/// IMPERATIVELY from the attachment-card tap (an AppKit click), not from an
/// `@Observable` field: the preview request originates from a click, so there
/// is no controller `@Observable` write to observe and no
/// `withObservationTracking` loop to re-arm.
///
/// **Why an owned presenter and not a free-hand `view.window?.beginSheet`**
/// (R5, HIGH): an orphaned modal sheet begun from a tap closure survives the
/// bar's teardown and WEDGES the window. This presenter is owned by
/// `InputBarController`, dismissed in its `prepareForRemoval()` / `stop()`,
/// idempotent on a double dismiss, and window-guarded (a present with no
/// window is a no-op, never a crash).
@MainActor
final class ImagePreviewPresenter {

    /// The view whose `.window` the sheet is begun on. Weak — the presenter
    /// outlives short-lived hosting situations and must not retain the bar.
    private weak var hostView: NSView?
    /// The currently-open sheet window (nil when none). Identity is implicit
    /// (only one preview at a time, the latest tap wins).
    private var openSheet: NSWindow?

    init(hostView: NSView) {
        self.hostView = hostView
    }

    nonisolated deinit {}

    /// Present `image` as a modal sheet on the host's window. Window-guarded:
    /// a no-op if the host is not windowed (no crash). If a preview is already
    /// open it is dismissed first so the latest tap wins.
    ///
    /// - Parameters:
    ///   - image: the thumbnail to preview (already-decoded — R19).
    ///   - envelope: the size envelope; defaults to the narrower input-bar one.
    ///   - imagePadding: image inset (input-bar default 20).
    func present(
        _ image: NSImage,
        envelope: ImagePreviewSheetViewController.Envelope = .inputBar,
        imagePadding: CGFloat = 20
    ) {
        guard let parent = hostView?.window else { return }
        // Latest tap wins — dismiss any in-flight preview first.
        dismiss()

        let vc = ImagePreviewSheetViewController(
            image: image, envelope: envelope, imagePadding: imagePadding,
            onDismiss: { [weak self] in self?.endCurrentSheet() })
        let window = Self.makeSheetWindow(contentViewController: vc, envelope: envelope)
        openSheet = window
        parent.beginSheet(window) { [weak self] _ in
            // Clear our handle when the sheet actually ends — guard against a
            // newer present having replaced it in the meantime.
            guard let self else { return }
            if self.openSheet === window { self.openSheet = nil }
        }
    }

    /// End the current sheet (Done / Return / click / Esc). Idempotent.
    func dismiss() {
        guard let window = openSheet else { return }
        if let parent = hostView?.window {
            parent.endSheet(window)
        }
        openSheet = nil
    }

    /// Symmetric teardown — alias for `dismiss()` to mirror
    /// `Transcript2SheetPresenter.stop()`. Called from
    /// `InputBarController.prepareForRemoval()`.
    func stop() { dismiss() }

    /// The Done/click/Return/Esc path: route through the window's `endSheet`
    /// so the `beginSheet` completion fires and clears `openSheet`.
    private func endCurrentSheet() {
        guard let window = openSheet, let parent = hostView?.window else {
            openSheet = nil
            return
        }
        parent.endSheet(window)
    }

    private static func makeSheetWindow(
        contentViewController: NSViewController,
        envelope: ImagePreviewSheetViewController.Envelope
    ) -> NSWindow {
        let window = NSWindow(contentViewController: contentViewController)
        window.isReleasedWhenClosed = false
        // `beginSheet` ignores a SwiftUI min/ideal/max envelope, so pin the
        // resizable bounds explicitly (§4.7-3). The VC's preferredContentSize
        // seeds the ideal content size on `contentViewController` assignment.
        window.contentMinSize = NSSize(width: envelope.minWidth, height: envelope.minHeight)
        window.contentMaxSize = NSSize(width: envelope.maxWidth, height: envelope.maxHeight)
        return window
    }
}
