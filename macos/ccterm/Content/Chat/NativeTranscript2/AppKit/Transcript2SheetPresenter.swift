import AppKit
import Observation
import SwiftUI

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
/// `TranscriptDetailViewController.startSelectionObservation`.
///
/// **Sheet content.** SwiftUI bodies (`UserBubbleSheetView` /
/// `ImagePreviewSheetView`) wrapped in `NSHostingController`. The body
/// content stays SwiftUI by design (project rule: "SwiftUI by default,
/// AppKit by exception" — the exception is the transcript's
/// frame-time cascade, not sheet decoration). Each body is wired with
/// an explicit `onDismiss` closure rather than `@Environment(\.dismiss)`
/// because AppKit-presented sheets do not propagate the SwiftUI
/// dismiss environment.
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
        observationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await withCheckedContinuation { cont in
                withObservationTracking {
                    _ = self.controller.pendingUserBubbleSheet
                    _ = self.controller.pendingImagePreview
                } onChange: {
                    Task { @MainActor in cont.resume() }
                }
            }
            guard !Task.isCancelled else { return }
            self.reconcile()
            self.startObservation()
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
        let body = UserBubbleSheetView(text: request.text) { [weak self] in
            self?.endCurrentSheet()
        }
        let sheet = Self.makeSheetWindow(rootView: body)
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
        let body = ImagePreviewSheetView(image: request.image) { [weak self] in
            self?.endCurrentSheet()
        }
        let sheet = Self.makeSheetWindow(rootView: body)
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

    private static func makeSheetWindow<Content: View>(rootView: Content) -> NSWindow {
        let hosting = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hosting)
        window.isReleasedWhenClosed = false
        return window
    }
}
