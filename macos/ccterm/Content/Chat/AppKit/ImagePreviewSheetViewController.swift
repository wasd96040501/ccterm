import AppKit

/// AppKit replacement for `ImagePreviewSheetView` (transcript path) AND
/// `InputBarView2.ImagePreviewView` (input-bar path) — one parameterized
/// preview surface for both callers (migration plan §4.7-1, R19). A PLAIN
/// `NSViewController` (NOT an `NSHostingController`): aspect-FIT `NSImageView`
/// (`.high` interpolation) on `windowBackgroundColor`, a divider, and a
/// trailing Done button.
///
/// Dismissal (§4.7-4): click anywhere on the image area, the Done button
/// (default action, keyEquivalent `\r`, window `initialFirstResponder` so
/// Return resolves to it), OR Esc (`cancelOperation`). All route through the
/// injected `onDismiss` closure — AppKit-presented sheets do NOT propagate the
/// SwiftUI dismiss environment, the same pattern `Transcript2SheetPresenter`
/// already uses for its bodies.
///
/// `viewWillDisappear` / `viewDidDisappear` are side-effect-free so a sheet
/// dismissed inside the transcript swap's disabled `CATransaction` does no
/// layout / async work mid-swap (§4.7-4).
@MainActor
final class ImagePreviewSheetViewController: NSViewController {

    /// The size envelope a caller hands the sheet — drives `contentMinSize` /
    /// `preferredContentSize` (ideal) / `contentMaxSize` (§4.7-3, R19). The two
    /// production callers differ:
    /// - `.transcript` — full-text image preview from the transcript chevron:
    ///   480 / 880 / 1400 × 360 / 660 / 1050 (ImagePreviewSheetView.swift:35-37).
    /// - `.inputBar` — the attachment-strip thumbnail preview: the narrower
    ///   360 / 520 / 800 × 280 / 420 / 720 (InputBarView2.swift:765-768).
    struct Envelope: Equatable {
        let minWidth: CGFloat
        let idealWidth: CGFloat
        let maxWidth: CGFloat
        let minHeight: CGFloat
        let idealHeight: CGFloat
        let maxHeight: CGFloat

        /// Transcript path — `ImagePreviewSheetView.swift:35-37`.
        static let transcript = Envelope(
            minWidth: 480, idealWidth: 880, maxWidth: 1400,
            minHeight: 360, idealHeight: 660, maxHeight: 1050)
        /// Input-bar path — `InputBarView2.swift:765-768`.
        static let inputBar = Envelope(
            minWidth: 360, idealWidth: 520, maxWidth: 800,
            minHeight: 280, idealHeight: 420, maxHeight: 720)
    }

    /// `padding(24)` (transcript ImagePreviewSheetView.swift:22) /
    /// `padding(20)` (input-bar InputBarView2.swift:756). Parameterized per
    /// caller alongside the envelope.
    private let imagePadding: CGFloat
    /// `.padding(12)` (transcript) / `.padding(12)` (input-bar) on the Done row.
    private static let doneRowPadding: CGFloat = 12

    private let image: NSImage
    let envelope: Envelope
    private let onDismiss: () -> Void

    private let imageView = NSImageView()
    private var doneButton: NSButton!

    // MARK: - Init

    /// - Parameters:
    ///   - image: the preview bitmap (the transcript hands the original; the
    ///     input bar hands the already-decoded thumbnail, matching today's
    ///     `InputBarView2.ImagePreviewView(thumbnail:)` — R19).
    ///   - envelope: the per-caller size envelope.
    ///   - imagePadding: 24 (transcript) / 20 (input bar).
    ///   - onDismiss: invoked on click / Return / Esc.
    init(
        image: NSImage,
        envelope: Envelope,
        imagePadding: CGFloat,
        onDismiss: @escaping () -> Void
    ) {
        self.image = image
        self.envelope = envelope
        self.imagePadding = imagePadding
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: envelope.idealWidth, height: envelope.idealHeight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    nonisolated deinit {}

    // MARK: - View

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        // Image area on a windowBackground panel (ImagePreviewSheetView.swift:17).
        // `ClickToDismissView` owns + re-resolves its own `windowBackgroundColor`
        // fill across appearance flips (R14).
        let imageArea = ClickToDismissView()
        imageArea.onClick = { [weak self] in self?.onDismiss() }
        imageArea.translatesAutoresizingMaskIntoConstraints = false

        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown  // aspect-FIT
        imageView.imageAlignment = .alignCenter
        imageView.animates = false
        // `.interpolation(.high)` (ImagePreviewSheetView.swift:20).
        imageView.wantsLayer = true
        imageView.layer?.minificationFilter = .trilinear
        imageView.layer?.magnificationFilter = .trilinear
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageArea.addSubview(imageView)

        // Divider + trailing Done row.
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let done = NSButton(
            title: String(localized: "Done"), target: self, action: #selector(donePressed))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"  // default action → Return resolves here.
        done.translatesAutoresizingMaskIntoConstraints = false
        doneButton = done

        let doneRow = NSView()
        doneRow.translatesAutoresizingMaskIntoConstraints = false
        doneRow.addSubview(done)

        root.addSubview(imageArea)
        root.addSubview(divider)
        root.addSubview(doneRow)

        NSLayoutConstraint.activate([
            imageArea.topAnchor.constraint(equalTo: root.topAnchor),
            imageArea.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            imageArea.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            imageView.leadingAnchor.constraint(
                equalTo: imageArea.leadingAnchor, constant: imagePadding),
            imageView.trailingAnchor.constraint(
                equalTo: imageArea.trailingAnchor, constant: -imagePadding),
            imageView.topAnchor.constraint(equalTo: imageArea.topAnchor, constant: imagePadding),
            imageView.bottomAnchor.constraint(
                equalTo: imageArea.bottomAnchor, constant: -imagePadding),

            divider.topAnchor.constraint(equalTo: imageArea.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            doneRow.topAnchor.constraint(equalTo: divider.bottomAnchor),
            doneRow.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            doneRow.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            doneRow.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            done.trailingAnchor.constraint(
                equalTo: doneRow.trailingAnchor, constant: -Self.doneRowPadding),
            done.topAnchor.constraint(equalTo: doneRow.topAnchor, constant: Self.doneRowPadding),
            done.bottomAnchor.constraint(
                equalTo: doneRow.bottomAnchor, constant: -Self.doneRowPadding),
        ])

        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Done is the initialFirstResponder so Return resolves to it (§4.7-4)
        // before any selectable text view can swallow it (no text view here,
        // but the contract is preserved for the shared body).
        view.window?.initialFirstResponder = doneButton
        view.window?.makeFirstResponder(doneButton)
    }

    // MARK: - Dismiss surfaces

    @objc private func donePressed() { onDismiss() }

    /// Esc → dismiss (§4.7-4).
    override func cancelOperation(_ sender: Any?) { onDismiss() }
}

/// An image-area backdrop whose click routes to `onClick` — reproduces the
/// SwiftUI `.contentShape(Rectangle()).onTapGesture { onDismiss() }`
/// (ImagePreviewSheetView.swift:24-25). A click anywhere on the panel (image
/// or the surrounding padding) dismisses.
///
/// Owns its own `windowBackgroundColor` layer fill (the SwiftUI panel was
/// `Color(nsColor: .windowBackgroundColor)`, ImagePreviewSheetView.swift:17)
/// and re-resolves it in `viewDidChangeEffectiveAppearance` — `CALayer`'s
/// `backgroundColor` does NOT auto-track a dark/light flip, so without this a
/// preview open across an appearance switch keeps the stale panel color (R14,
/// the same fix as `AttachmentCardView`). The re-resolution lives here, on the
/// `NSView`, because `viewDidChangeEffectiveAppearance` is an `NSView` hook —
/// `NSViewController` does not have one.
private final class ClickToDismissView: NSView {
    var onClick: (() -> Void)?
    nonisolated deinit {}

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        applyBackground()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackground()
    }

    private func applyBackground() {
        // `NSColor.windowBackgroundColor.cgColor` resolves against
        // `NSColor.current`, which is NOT guaranteed to be this view's
        // appearance inside `viewDidChangeEffectiveAppearance`, so resolve
        // explicitly against `effectiveAppearance`.
        var fill: CGColor = NSColor.windowBackgroundColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fill = NSColor.windowBackgroundColor.cgColor
        }
        // Wrapped in a disabled `CATransaction` so the color never crossfades.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = fill
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        // Hold for the up so a drag off the area doesn't dismiss.
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }
}
