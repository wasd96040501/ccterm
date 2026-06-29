import AppKit
import Observation

/// Bridges `Transcript2Controller`'s two `@Observable` sheet-request
/// fields (`pendingUserBubbleSheet` / `pendingImagePreview`) to AppKit-
/// native sheet presentation. Replaces the SwiftUI `.sheet(item:)`
/// bindings that lived on the old `NativeTranscript2View` bridge — host
/// VCs are pure AppKit now, so the presentation primitive has to live
/// here too.
///
/// **Lifecycle.** Created by the host VC alongside its transcript scroll
/// view; tear down via `stop()` before the host's window is gone.
/// Observation tracking re-arms itself by tail-recursing through
/// `startObservation()` — same pattern as
/// `ChatSessionViewController.startSelectionObservation`.
///
/// **Sheet content.** Pure-AppKit `NSViewController`s
/// (`UserBubbleSheetViewController` / `ImagePreviewSheetViewController`)
/// set as the sheet window's `contentViewController` directly — no
/// `NSHostingController`, no SwiftUI on the page (migration plan §4.7).
/// Each VC is wired with an explicit `onDismiss` closure rather than
/// `@Environment(\.dismiss)` because AppKit-presented sheets do not
/// propagate the SwiftUI dismiss environment. The window's
/// `contentMinSize` / `contentMaxSize` are pinned from each VC's
/// `Envelope` (§4.7-3) since `beginSheet` honors no SwiftUI min/ideal/max
/// frame; the VC's `preferredContentSize` seeds the ideal.
///
/// **Coalescing.** The same source-phase tick can write both fields
/// (rare but allowed); we present whichever side has a value, with
/// user-bubble priority. Sheet identity is tracked via an
/// `OpenSheetTag` so a no-op observation hop doesn't churn the sheet
/// closed-then-open.
@MainActor
final class Transcript2SheetPresenter {

    private let controller: Transcript2Controller
    private weak var hostView: NSView?
    private var observationTask: Task<Void, Never>?
    private var openSheet: (window: NSWindow, tag: OpenSheetTag)?

    private enum OpenSheetTag: Equatable {
        case userBubble(UUID)
        case imagePreview(UUID)
    }

    /// `hostView` resolves to `.window` at present time — captured weakly
    /// because the presenter outlives short-lived hosting situations
    /// (e.g. live-resize repackaging).
    init(controller: Transcript2Controller, hostView: NSView) {
        self.controller = controller
        self.hostView = hostView
        startObservation()
        // Reconcile once at construction so a controller that was
        // pre-set (e.g. inside a snapshot test) does not silently
        // strand its pending request.
        reconcile()
    }

    /// Symmetric teardown — cancels the observation task and dismisses
    /// any open sheet. Idempotent.
    func stop() {
        observationTask?.cancel()
        observationTask = nil
        dismissOpenSheet()
    }

    deinit {
        observationTask?.cancel()
    }

    // MARK: - Observation

    private func startObservation() {
        observationTask?.cancel()
        // Capture `controller` (owned by the `Session`, never by us) so the
        // suspended task holds no strong `self`. Re-acquire `self` weakly
        // only AFTER each resume.
        //
        // The old shape was `guard let self` at the top, which bound a
        // strong `self` that lived across the `withCheckedContinuation`
        // suspension — a task↔presenter retain cycle. `stop()` / `deinit`
        // cancel the task, but cancellation does not resume a suspended
        // `withCheckedContinuation`, so the strong `self` lingered until
        // the observed fields next changed — which, for a session detached
        // mid-attach, is never. Result: one leaked presenter per session
        // switch (every `attachSession` builds a fresh one). The loop form
        // below mirrors `ChatSessionViewController.startRunningObservation`.
        let controller = self.controller
        observationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await withCheckedContinuation { cont in
                    withObservationTracking {
                        _ = controller.pendingUserBubbleSheet
                        _ = controller.pendingImagePreview
                    } onChange: {
                        Task { @MainActor in cont.resume() }
                    }
                }
                guard !Task.isCancelled, let self else { return }
                self.reconcile()
            }
        }
    }

    private func reconcile() {
        let desired: OpenSheetTag? = {
            if let b = controller.pendingUserBubbleSheet { return .userBubble(b.id) }
            if let i = controller.pendingImagePreview { return .imagePreview(i.id) }
            return nil
        }()

        if desired == openSheet?.tag { return }
        dismissOpenSheet()

        guard let desired else { return }
        switch desired {
        case .userBubble(let id):
            // Guard against the field being mutated between observation
            // and reconcile (rare but possible if a sibling task wrote
            // while our hop was in flight).
            if let request = controller.pendingUserBubbleSheet, request.id == id {
                presentBubble(request)
            }
        case .imagePreview(let id):
            if let request = controller.pendingImagePreview, request.id == id {
                presentImage(request)
            }
        }
    }

    // MARK: - Presentation

    private func presentBubble(_ request: UserBubbleSheetRequest) {
        guard let parent = hostView?.window else {
            controller.pendingUserBubbleSheet = nil
            return
        }
        let vc = UserBubbleSheetViewController(text: request.text) { [weak self] in
            self?.endCurrentSheet()
        }
        let sheet = Self.makeSheetWindow(
            contentViewController: vc,
            minSize: NSSize(width: vc.envelope.minWidth, height: vc.envelope.minHeight),
            maxSize: NSSize(width: vc.envelope.maxWidth, height: vc.envelope.maxHeight))
        openSheet = (sheet, .userBubble(request.id))
        parent.beginSheet(sheet) { [weak self] _ in
            guard let self else { return }
            if case .userBubble(let openId)? = self.openSheet?.tag, openId == request.id {
                self.openSheet = nil
            }
            // Clear the field only if it still matches this request —
            // a brand-new request that landed between endSheet and
            // this completion handler must not be wiped.
            if self.controller.pendingUserBubbleSheet?.id == request.id {
                self.controller.pendingUserBubbleSheet = nil
            }
        }
    }

    private func presentImage(_ request: ImagePreviewRequest) {
        guard let parent = hostView?.window else {
            controller.pendingImagePreview = nil
            return
        }
        let vc = ImagePreviewSheetBody.makeTranscriptViewController(image: request.image) {
            [weak self] in
            self?.endCurrentSheet()
        }
        let sheet = Self.makeSheetWindow(
            contentViewController: vc,
            minSize: NSSize(width: vc.envelope.minWidth, height: vc.envelope.minHeight),
            maxSize: NSSize(width: vc.envelope.maxWidth, height: vc.envelope.maxHeight))
        openSheet = (sheet, .imagePreview(request.id))
        parent.beginSheet(sheet) { [weak self] _ in
            guard let self else { return }
            if case .imagePreview(let openId)? = self.openSheet?.tag, openId == request.id {
                self.openSheet = nil
            }
            if self.controller.pendingImagePreview?.id == request.id {
                self.controller.pendingImagePreview = nil
            }
        }
    }

    private func endCurrentSheet() {
        guard let parent = hostView?.window, let entry = openSheet else { return }
        parent.endSheet(entry.window)
    }

    private func dismissOpenSheet() {
        guard let parent = hostView?.window, let entry = openSheet else {
            openSheet = nil
            return
        }
        parent.endSheet(entry.window)
        openSheet = nil
    }

    /// Build the sheet window hosting a pure-AppKit `contentViewController`
    /// directly (no `NSHostingController`). `beginSheet` ignores a SwiftUI
    /// min/ideal/max envelope, so the resizable bounds are pinned explicitly
    /// (§4.7-3); the VC's `preferredContentSize` (seeded from its `Envelope`
    /// ideal) supplies the initial content size on assignment.
    private static func makeSheetWindow(
        contentViewController: NSViewController,
        minSize: NSSize,
        maxSize: NSSize
    ) -> NSWindow {
        let window = NSWindow(contentViewController: contentViewController)
        window.isReleasedWhenClosed = false
        window.contentMinSize = minSize
        window.contentMaxSize = maxSize
        return window
    }
}
