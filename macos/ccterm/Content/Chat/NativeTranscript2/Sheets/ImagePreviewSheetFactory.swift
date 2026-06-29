import AppKit

/// The transcript-side image-preview sheet factory — the AppKit replacement for
/// the SwiftUI `ImagePreviewSheetView` body that `Transcript2SheetPresenter`
/// hosts via `NSHostingController` today (migration plan §4.7).
///
/// **There is no new preview VIEW here, on purpose.** Phase 1 already shipped
/// the parameterized `ImagePreviewSheetViewController` (aspect-fit
/// `NSImageView`, divider, trailing Done button, click / Return / Esc dismiss)
/// for the input-bar attachment preview, and that VC already carries the
/// transcript size envelope (`Envelope.transcript` = 480 / 880 / 1400 ×
/// 360 / 660 / 1050, matching `ImagePreviewSheetView.swift:35-37`) and the
/// transcript image inset (`24`, matching `ImagePreviewSheetView.swift:22`).
/// Building a second image-preview NSView would duplicate that logic, which the
/// plan explicitly forbids ("do NOT duplicate image-preview logic … may simply
/// route to that existing VC").
///
/// So this file is the **one shared seam** the transcript path uses to build
/// that VC with its own (wider) envelope and padding. When the integration
/// step flips `Transcript2SheetPresenter.presentImage` off the SwiftUI body, it
/// calls `ImagePreviewSheetFactory.makeTranscriptViewController(image:onDismiss:)`
/// instead of constructing an `NSHostingController(rootView: ImagePreviewSheetView)`.
/// Keeping the transcript's envelope/padding constants pinned here (rather than
/// inline at the call site) means the transcript ↔ input-bar parity is checked
/// by a test against this seam, not by re-reading the presenter.
@MainActor
enum ImagePreviewSheetFactory {

    /// The transcript image-preview envelope — the generous full-text preview
    /// size from `ImagePreviewSheetView.swift:35-37` (`minWidth: 480`,
    /// `idealWidth: 880`, `maxWidth: 1400`, `minHeight: 360`, `idealHeight: 660`,
    /// `maxHeight: 1050`). Exposed as the shared source of truth so a test can
    /// assert the transcript path uses the wider envelope (vs the input bar's
    /// narrower `.inputBar`).
    static let envelope: ImagePreviewSheetViewController.Envelope = .transcript

    /// The transcript image inset — `padding(24)` in `ImagePreviewSheetView.swift:22`
    /// (the input bar uses the tighter `20`, `InputBarView2.swift:756`).
    static let imagePadding: CGFloat = 24

    /// Build the transcript image-preview sheet body.
    ///
    /// Routes to the shared `ImagePreviewSheetViewController` configured with
    /// the transcript envelope + padding above — one preview surface for both
    /// the transcript chevron and the input-bar attachment chip (plan §4.7-1,
    /// R19). The returned VC is a plain `NSViewController` (NOT an
    /// `NSHostingController`), so `Transcript2SheetPresenter.makeSheetWindow`
    /// can host it as `contentViewController` once the SwiftUI body is removed.
    ///
    /// - Parameters:
    ///   - image: the full preview bitmap (the transcript hands the original
    ///     `NSImage`, matching `ImagePreviewRequest.image`).
    ///   - onDismiss: invoked on click on the image area / Done (Return default
    ///     action) / Esc. The transcript presenter routes this through its
    ///     `endSheet` so the `beginSheet` completion fires (same shape as the
    ///     SwiftUI body's injected `onDismiss`, which AppKit-presented sheets
    ///     need because they do not propagate `@Environment(\.dismiss)`).
    /// - Returns: a configured `ImagePreviewSheetViewController`.
    static func makeTranscriptViewController(
        image: NSImage,
        onDismiss: @escaping () -> Void
    ) -> ImagePreviewSheetViewController {
        ImagePreviewSheetViewController(
            image: image,
            envelope: envelope,
            imagePadding: imagePadding,
            onDismiss: onDismiss)
    }
}
