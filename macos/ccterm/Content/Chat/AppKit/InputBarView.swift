import AppKit
import UniformTypeIdentifiers

/// AppKit replacement for the SwiftUI `InputBarView2` pill (migration plan
/// §4.1) — the SPINE: a hand-laid-out NSView that places the standalone
/// attach button and the rounded "pill" (text field + send/stop button) with
/// the exact pixel-numeric frame math the SwiftUI bar used. The thumbnail
/// strip and the completion popup are co-delivered components (§4.3) that
/// plug into the same `relayout()` funnel via the `extraPillContentHeight`
/// accumulator; the spine leaves them at 0.
///
/// Layout mirrors `InputBarView2.body`:
///
/// ```
/// HStack(alignment: .bottom, spacing: attachToPillSpacing) {
///     AttachButtonView          // 32pt circle, bottom-anchored
///     pill                      // BarSurfaceView(16), grows up
/// }
/// ```
///
/// - The attach button is bottom-aligned to the pill so the `+` stays glued
///   to the bottom text row even when the pill grows upward (matching the
///   SwiftUI `.bottom` alignment rationale, `InputBarView2.swift:132-139`).
/// - The pill's bottom 32pt row holds the text scroll + the send/stop button
///   (concentric with the bottom-right corner: `sendButtonInset = 4`).
/// - HEIGHT is content-driven (regime B): `relayout()` sums the text view's
///   own intrinsic height (clamped to `pillMinHeight`) plus any extra pill
///   content, and publishes it through `intrinsicContentSize`. WIDTH is
///   `noIntrinsicMetric` so it never leaks `fittingSize.width` up into the
///   window constraint solver (plan R1).
final class InputBarView: NSView {

    // MARK: - Constants (verbatim from InputBarView2.swift)

    static let cornerRadius: CGFloat = 16
    static let pillMinHeight: CGFloat = 32
    static let sendButtonInset: CGFloat = 4
    static let attachToPillSpacing: CGFloat = 8
    static let textLeadingPadding: CGFloat = 12
    static let textTrailingPadding: CGFloat = 4
    /// `textContainerInset` height — makes the scroll frame fill the full
    /// 32pt pill so clicks on the padded strip focus the field
    /// (`InputBarView2.swift:29`, `InputTextView.swift:13-17`).
    static let textVerticalPadding: CGFloat = 7.5
    /// Drop-target pill stroke (`InputBarView2.swift:273-276`).
    private static let dropStrokeLineWidth: CGFloat = 1.5
    private static let dropStrokeDash: [CGFloat] = [6, 4]
    /// `.smooth(duration: 0.35)` attachment grow/shrink animation
    /// (`InputBarView2.swift:152`, `animationDuration`).
    static let attachmentAnimationDuration: TimeInterval = 0.35
    /// `.easeOut(duration: 0.12)` drop-target stroke toggle
    /// (`InputBarView2.swift:150`).
    static let dropStrokeAnimationDuration: TimeInterval = 0.12

    // MARK: - Subviews

    let attachButton = AttachButtonView()
    let sendStopButton = SendStopButton()
    /// The raw text core, embedded directly (UNWRAP — no `TextInputView`).
    let textScrollView: InputTextScrollView
    let textView: InputNSTextView
    /// The in-pane completion popup (§4.3), mounted ABOVE the text row inside
    /// the pill content. Created once, hidden/shown via `isHidden`; its fixed
    /// height feeds `extraPillContentHeight` so the bottom-anchored pill grows
    /// UP to contain it (the attach button + text row never move).
    let completionPopup = CompletionPopupView()

    /// 1pt hairline separating the completion popup from the bottom text row,
    /// reproducing the SwiftUI `Divider()` between `CompletionListView` and the
    /// text `HStack` (`InputBarView2.swift:213-219`). Lives OUTSIDE the popup's
    /// `listHeight`-framed height (exactly as the SwiftUI `Divider` lived
    /// outside the popup's `.frame(height: listHeight)`), so the bar reserves
    /// `listHeight + dividerHeight` when the popup is active. Hidden with the
    /// popup.
    private let completionDivider = NSView()
    /// A SwiftUI `Divider()` is a 1pt hairline.
    static let completionDividerHeight: CGFloat = 1

    /// The attachment thumbnail strip (§4.1, §4.7-1), mounted ABOVE the text
    /// row and BELOW the completion popup (the SwiftUI pill ordered the
    /// completion popup above the strip — InputBarView2.swift:206-223). Hidden
    /// until the controller reconciles it with ≥1 attachment; its fixed 64pt
    /// height feeds `extraPillContentHeight` so the pill grows up to contain it.
    let attachmentStrip = AttachmentStripView()
    /// 1pt hairline between the strip and the bottom text row, reproducing the
    /// SwiftUI `Divider()` between `thumbnailStrip` and the text `HStack`
    /// (InputBarView2.swift:220-223). Lives OUTSIDE the strip's framed height.
    private let stripDivider = NSView()

    private let pillSurface = BarSurfaceView(cornerRadius: InputBarView.cornerRadius)
    /// The pill's interior content view (clipped to the rounded shape by
    /// `pillSurface.setContentView`). The text scroll + send button live
    /// here; the completion popup / strip mount here later.
    private let pillContent = FlippedView()
    private let dropStrokeLayer = CAShapeLayer()

    // MARK: - Layout accumulators (filled by co-delivered components)

    /// Extra height the pill must reserve ABOVE the bottom text row — the
    /// completion popup (§4.3) and the thumbnail strip (§4.1-9) add their
    /// fixed heights here. It is the SUM of `completionBandHeight` +
    /// `stripBandHeight`, recomputed whenever either band toggles. The spine
    /// keeps both at 0. Setting it re-funnels.
    var extraPillContentHeight: CGFloat = 0 {
        didSet {
            guard extraPillContentHeight != oldValue else { return }
            relayout()
        }
    }

    /// The completion popup's reserved height (popup `listHeight` + 1pt
    /// divider, 0 when inactive). Summed into `extraPillContentHeight`.
    private var completionBandHeight: CGFloat = 0
    /// The attachment strip's reserved height (64pt strip + 1pt divider, 0 when
    /// no attachment). Summed into `extraPillContentHeight`.
    private var stripBandHeight: CGFloat = 0

    /// The view scrim-cutout rects are reported relative to — set by the
    /// controller to `inputBarController.view` (the new `convert(from:)`
    /// anchor, plan §4.1-2). When nil, reporting is disabled (previews).
    weak var scrimAnchorView: NSView?
    /// Fired in `layout()` (post-`super.layout()`, frames settled) with the
    /// attach button's frame converted to `scrimAnchorView`.
    var onAttachRect: ((CGRect) -> Void)?
    /// Fired in `layout()` with the pill's frame converted to
    /// `scrimAnchorView`. Reported separately so the 8pt gap is not cut.
    var onPillRect: ((CGRect) -> Void)?

    // MARK: - Drop wiring (plan §4.1-9, §4.7-1)

    /// `acceptedDropTypes` mapped to pasteboard type identifiers
    /// (`InputBarView2.swift:49-51` — `.fileURL, .image, .png, .jpeg, .tiff,
    /// .heic, .gif, .bmp, .webP`). Registered in `init`.
    private static let acceptedDragPasteboardTypes: [NSPasteboard.PasteboardType] = {
        let utTypes: [UTType] = [.fileURL, .image, .png, .jpeg, .tiff, .heic, .gif, .bmp, .webP]
        return utTypes.map { NSPasteboard.PasteboardType($0.identifier) }
    }()

    /// Called when a drag enters / updates over the bar. The controller drives
    /// the dashed-stroke highlight via `setDropTargeted(_:)`.
    var onDropTargetedChanged: ((Bool) -> Void)?
    /// Called on `performDragOperation` with the drop's `NSItemProvider`s
    /// reconstructed from the dragging pasteboard so the controller's verbatim
    /// `loadAsURL` / `loadAsImageData` loaders run unchanged. Returns whether
    /// at least one provider was consumed.
    var onPerformDrop: (([NSItemProvider]) -> Bool)?

    // MARK: - Constraints driven by relayout

    private var pillHeightConstraint: NSLayoutConstraint!
    /// Pins the text row top to the completion divider (strip inactive). Active
    /// when no attachment strip is shown — preserves the spine's exact chain.
    private var completionDividerToText: NSLayoutConstraint!
    /// Pins the text row top to the strip divider (strip active). Active only
    /// while ≥1 attachment is shown.
    private var stripDividerToText: NSLayoutConstraint!
    /// Whether the attachment strip is currently in the chain.
    private(set) var isAttachmentStripActive = false
    /// The last attach/pill rects reported through `onAttachRect`/`onPillRect`
    /// (converted to `scrimAnchorView`). `private(set)` is an access-modifier-only
    /// test seam — the integration gate asserts the rects production REPORTS are
    /// stable across a completion-popup open/close (plan §4.1-2 / R6) without a
    /// re-implementation. No behavior change.
    private(set) var lastReportedAttachRect: CGRect = .null
    private(set) var lastReportedPillRect: CGRect = .null

    // MARK: - Init

    init() {
        textScrollView = InputTextScrollView()
        textView = InputNSTextView(usingTextLayoutManager: true)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        configureTextCore()
        assemble()
        registerForDraggedTypes(Self.acceptedDragPasteboardTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    nonisolated deinit {}

    // MARK: - Text core (verbatim setup from TextInputView.makeNSView)

    private func configureTextCore() {
        textScrollView.hasVerticalScroller = false
        textScrollView.hasHorizontalScroller = false
        textScrollView.verticalScrollElasticity = .none
        textScrollView.drawsBackground = false
        textScrollView.borderType = .noBorder
        textScrollView.translatesAutoresizingMaskIntoConstraints = false

        textView.isRichText = false
        textView.allowsUndo = true
        // 14pt — the chat bar's font (`InputBarView2.swift:328`); NOT the
        // 13pt `TextInputView` default.
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 0, height: Self.textVerticalPadding)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.placeholderString = String(localized: "Send a message")
        textView.placeholderFont = .systemFont(ofSize: 14)

        textScrollView.documentView = textView

        let lineHeight = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 14))
        textScrollView.lineHeight = lineHeight
        textScrollView.minLines = 1
        textScrollView.maxLines = 10
        textScrollView.updateIntrinsicHeight()
    }

    // MARK: - Assembly

    private func assemble() {
        attachButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(attachButton)

        pillSurface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pillSurface)

        pillContent.translatesAutoresizingMaskIntoConstraints = false
        pillSurface.setContentView(pillContent)

        // Text scroll + send button live in the bottom 32pt row of the pill.
        pillContent.addSubview(textScrollView)
        pillContent.addSubview(sendStopButton)

        // Completion popup mounted ABOVE the text row inside the pill content.
        // Hidden until the controller reconciles it active; its height is owned
        // by its own @required constraint and routed into the bar's
        // `extraPillContentHeight` so the pill grows up to contain it.
        completionPopup.translatesAutoresizingMaskIntoConstraints = false
        pillContent.addSubview(completionPopup)

        // 1pt hairline between the popup and the text row (matches the SwiftUI
        // `Divider()`); hidden with the popup.
        completionDivider.translatesAutoresizingMaskIntoConstraints = false
        completionDivider.wantsLayer = true
        completionDivider.isHidden = true
        applyCompletionDividerColor()
        pillContent.addSubview(completionDivider)

        // Attachment strip + its divider, mounted between the completion popup
        // divider and the text row. Hidden (collapsed to 0 in the chain) until
        // the controller reconciles ≥1 attachment.
        attachmentStrip.translatesAutoresizingMaskIntoConstraints = false
        attachmentStrip.isHidden = true
        pillContent.addSubview(attachmentStrip)

        stripDivider.translatesAutoresizingMaskIntoConstraints = false
        stripDivider.wantsLayer = true
        stripDivider.isHidden = true
        applyStripDividerColor()
        pillContent.addSubview(stripDivider)

        // Drop-target stroke overlay on the pill (hidden until targeted).
        dropStrokeLayer.fillColor = nil
        dropStrokeLayer.lineWidth = Self.dropStrokeLineWidth
        dropStrokeLayer.lineDashPattern = Self.dropStrokeDash.map { NSNumber(value: Double($0)) }
        dropStrokeLayer.isHidden = true
        dropStrokeLayer.opacity = 0
        layer?.addSublayer(dropStrokeLayer)

        pillHeightConstraint = pillSurface.heightAnchor.constraint(
            equalToConstant: Self.pillMinHeight)
        pillHeightConstraint.priority = .required

        NSLayoutConstraint.activate([
            // Attach button: bottom-left, fixed 32×32.
            attachButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            attachButton.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Pill: fills the remaining width, 8pt to the right of attach,
            // bottom-anchored, top pins the view's top so the bar grows up.
            pillSurface.leadingAnchor.constraint(
                equalTo: attachButton.trailingAnchor, constant: Self.attachToPillSpacing),
            pillSurface.trailingAnchor.constraint(equalTo: trailingAnchor),
            pillSurface.topAnchor.constraint(equalTo: topAnchor),
            pillSurface.bottomAnchor.constraint(equalTo: bottomAnchor),
            pillHeightConstraint,

            // Text scroll: leading 12 / trailing 4, sized for the BOTTOM
            // 32pt row (its own intrinsic height drives the row height,
            // capped at pillMinHeight by the row), bottom-anchored.
            textScrollView.leadingAnchor.constraint(
                equalTo: pillContent.leadingAnchor, constant: Self.textLeadingPadding),
            textScrollView.bottomAnchor.constraint(equalTo: pillContent.bottomAnchor),
            textScrollView.heightAnchor.constraint(
                greaterThanOrEqualToConstant: Self.pillMinHeight),

            // Send button: concentric with the bottom-right corner.
            sendStopButton.trailingAnchor.constraint(
                equalTo: pillContent.trailingAnchor, constant: -Self.sendButtonInset),
            sendStopButton.bottomAnchor.constraint(
                equalTo: pillContent.bottomAnchor, constant: -Self.sendButtonInset),
            // Text scroll's trailing meets the send button's leading (4pt gap).
            textScrollView.trailingAnchor.constraint(
                equalTo: sendStopButton.leadingAnchor, constant: -Self.textTrailingPadding),

            // Completion popup: full-width above the text row. Its OWN
            // @required height constraint governs its height; the bar reserves
            // that height (plus the divider) via `extraPillContentHeight` (so
            // the pill grows up). Its bottom sits at the divider's top, and the
            // divider's bottom meets the text scroll's top (so the bottom text
            // row never moves); its top is a NON-required `>=` so the popup's
            // own height drives it and there's no over-constraint with the pill
            // height. When inactive the popup + divider are hidden (height 0).
            completionPopup.leadingAnchor.constraint(equalTo: pillContent.leadingAnchor),
            completionPopup.trailingAnchor.constraint(equalTo: pillContent.trailingAnchor),
            completionPopup.bottomAnchor.constraint(equalTo: completionDivider.topAnchor),

            // The 1pt hairline between popup and the band below it (the strip
            // when active, else the text row).
            completionDivider.leadingAnchor.constraint(equalTo: pillContent.leadingAnchor),
            completionDivider.trailingAnchor.constraint(equalTo: pillContent.trailingAnchor),
            completionDivider.heightAnchor.constraint(equalToConstant: Self.completionDividerHeight),

            // Attachment strip: full-width, between the completion divider and
            // the strip divider. Its OWN @required 64pt height drives the band;
            // the bar reserves it via `extraPillContentHeight`. Edges only here.
            attachmentStrip.leadingAnchor.constraint(equalTo: pillContent.leadingAnchor),
            attachmentStrip.trailingAnchor.constraint(equalTo: pillContent.trailingAnchor),
            attachmentStrip.topAnchor.constraint(equalTo: completionDivider.bottomAnchor),

            // The 1pt hairline between the strip and the text row.
            stripDivider.leadingAnchor.constraint(equalTo: pillContent.leadingAnchor),
            stripDivider.trailingAnchor.constraint(equalTo: pillContent.trailingAnchor),
            stripDivider.topAnchor.constraint(equalTo: attachmentStrip.bottomAnchor),
            stripDivider.heightAnchor.constraint(equalToConstant: Self.completionDividerHeight),
        ])

        // The text row's top pins to EITHER the completion divider (strip
        // inactive — preserves the spine's exact chain so the completion popup
        // tests are unaffected) OR the strip divider (strip active). Exactly one
        // is active at a time; toggled in `setAttachmentStrip(active:)`.
        completionDividerToText = completionDivider.bottomAnchor.constraint(
            equalTo: textScrollView.topAnchor)
        stripDividerToText = stripDivider.bottomAnchor.constraint(
            equalTo: textScrollView.topAnchor)
        completionDividerToText.isActive = true
        stripDividerToText.isActive = false

        let popupTop = completionPopup.topAnchor.constraint(
            greaterThanOrEqualTo: pillContent.topAnchor)
        popupTop.priority = .defaultHigh
        popupTop.isActive = true

        // Hook the text view's intrinsic-height funnel into our relayout.
        textScrollView.onIntrinsicHeightChanged = { [weak self] in
            self?.relayout()
        }

        relayout()
    }

    // MARK: - Relayout funnel (plan §4.1-1)

    /// The SINGLE funnel that recomputes the pill height from the text view's
    /// own intrinsic height (clamped to `pillMinHeight`) + any extra content,
    /// then re-publishes the bar's intrinsic height. EVERY mutator (text
    /// height change, attachment add/remove, completion show/hide) calls this.
    /// Never compute the pill height independently of the text view.
    ///
    /// - Parameter animated: when `true`, the height-constant change + the
    ///   superview settle run inside an `NSAnimationContext.runAnimationGroup`
    ///   at `.smooth(0.35)` — matching the SwiftUI bar's
    ///   `.animation(.smooth(duration: 0.35), value: attachments.isEmpty)` for
    ///   the attachment grow/shrink. Text-driven height changes stay instant
    ///   (the SwiftUI bar did NOT animate text growth), so the text funnel
    ///   passes `animated: false`.
    func relayout(animated: Bool = false) {
        let textHeight = max(Self.pillMinHeight, textScrollView.intrinsicContentSize.height)
        let pillHeight = textHeight + extraPillContentHeight
        guard abs(pillHeightConstraint.constant - pillHeight) > 0.5 else {
            invalidateIntrinsicContentSize()
            return
        }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.attachmentAnimationDuration
                ctx.allowsImplicitAnimation = true
                pillHeightConstraint.animator().constant = pillHeight
                invalidateIntrinsicContentSize()
                superview?.layoutSubtreeIfNeeded()
            }
        } else {
            pillHeightConstraint.constant = pillHeight
            invalidateIntrinsicContentSize()
        }
        // The published intrinsic HEIGHT changed; tell the regime-B host to
        // re-query its own cached intrinsic size (which reads our fitting height)
        // so the intrinsic-size path can't keep a stale value (R7).
        onIntrinsicHeightChanged?()
    }

    // MARK: - Completion popup show/hide (plan §4.3)

    /// Show/hide the completion popup and reserve its fixed height, INSTANTLY
    /// (matching the SwiftUI `.animation(nil)` resize, §4.3). Wrapped in a
    /// disabled `CATransaction` so an enclosing animation context can't make
    /// the popup crossfade/slide. `extraPillContentHeight`'s `didSet` funnels
    /// through `relayout()`, which re-sums and re-publishes the bar height.
    ///
    /// - Parameters:
    ///   - active: whether the popup is visible (`completion.isActive`).
    ///   - listHeight: the popup's fixed height from `CompletionListLayout`.
    func setCompletionPopup(active: Bool, listHeight: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.allowsImplicitAnimation = false

        completionPopup.isHidden = !active
        completionDivider.isHidden = !active
        if !active { completionPopup.prepareForHide() }
        // Reserve the popup's framed height PLUS the 1pt divider (which the
        // SwiftUI `Divider()` added outside `listHeight`), so the pill grows up
        // to contain both. 0 when inactive.
        completionBandHeight = active ? listHeight + Self.completionDividerHeight : 0
        extraPillContentHeight = completionBandHeight + stripBandHeight

        NSAnimationContext.endGrouping()
        CATransaction.commit()
    }

    // MARK: - Attachment strip show/hide (plan §4.1-9, §4.7-1)

    /// Reconcile the attachment strip's cards from `attachments` and show/hide
    /// the strip band. Mirrors `setCompletionPopup`: the strip's fixed 64pt
    /// height (+ 1pt divider) reserves room in `extraPillContentHeight` so the
    /// pill grows UP to contain it; an empty array collapses the band to 0. The
    /// strip's presence drives the bar's grow/shrink, which the caller animates
    /// via `relayout(animated:)` at `.smooth(0.35)` (the band toggle here is
    /// instant — the height re-sum is the animated part).
    func setAttachmentStrip(_ attachments: [Attachment]) {
        let active = !attachments.isEmpty

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.allowsImplicitAnimation = false

        // Always reconcile — `reconcile([])` removes all cards so the strip is
        // empty when it collapses (the cards must not linger after a send/clear).
        attachmentStrip.reconcile(attachments)
        attachmentStrip.isHidden = !active
        stripDivider.isHidden = !active
        // active (preserves the spine's exact chain when no attachment).
        if active != isAttachmentStripActive {
            isAttachmentStripActive = active
            completionDividerToText.isActive = !active
            stripDividerToText.isActive = active
        }

        stripBandHeight = active ? AttachmentStripView.stripHeight + Self.completionDividerHeight : 0
        extraPillContentHeight = completionBandHeight + stripBandHeight

        NSAnimationContext.endGrouping()
        CATransaction.commit()
    }

    // MARK: - Sizing (regime B — content drives height; width is free)

    override var intrinsicContentSize: NSSize {
        // WIDTH must stay noIntrinsicMetric (R1) so it can never leak
        // `fittingSize.width` up. HEIGHT = the pill's current height (the
        // attach button is shorter and bottom-aligned, so it never governs).
        //
        // INVARIANT: the pill height is owned SOLELY by `pillHeightConstraint`
        // (set imperatively in `relayout()` from the text height + the reserved
        // strip/popup bands). The content chain only pins `textScrollView.bottom`
        // to `pillContent.bottom` — the attachment strip + dividers are pinned
        // ABOVE the text row, never to `pillContent.bottom`. This matters because
        // `AttachmentStripView.heightConstraint` is @required and always-active
        // (it is not deactivated when the strip is hidden); if the strip/divider
        // chain were ever pinned to `pillContent.bottom`, the hidden 64pt strip
        // would pump the idle bar height. Keep the bottom of the content chain
        // anchored to the text row only.
        //
        // NOTE: `height == pillHeight` is only correct because
        // `pillMinHeight (32) >= AttachButtonView.size (32)` — the two
        // coincide today. If the attach button ever exceeds the pill's
        // minimum, this must become `max(pillHeight, attachButton bottom)`.
        NSSize(width: NSView.noIntrinsicMetric, height: pillHeightConstraint.constant)
    }

    // MARK: - Drop-target stroke

    private(set) var isDropTargeted: Bool = false

    /// Toggle the dashed accent stroke on the pill AND the attach button in
    /// ONE `NSAnimationContext` group so they fade in/out together at
    /// `.easeOut(0.12)` — matching `InputBarView2`'s
    /// `.animation(.easeOut(duration: 0.12), value: isDropTargeted)` on both
    /// surfaces (§4.1-9). Opacity-driven so the dashed stroke never pops.
    func setDropTargeted(_ targeted: Bool) {
        guard targeted != isDropTargeted else { return }
        isDropTargeted = targeted
        // Keep both layers present; animate alpha so easeOut reads.
        dropStrokeLayer.isHidden = false
        applyDropStrokeColor()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.dropStrokeAnimationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            dropStrokeLayer.opacity = targeted ? 1 : 0
            attachButton.setDropTargeted(targeted, in: ctx)
        } completionHandler: { [weak self] in
            // Hide once fully faded out so it can't intercept anything.
            if self?.isDropTargeted == false { self?.dropStrokeLayer.isHidden = true }
        }
    }

    private func applyDropStrokeColor() {
        var resolved: CGColor = NSColor.controlAccentColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.controlAccentColor.cgColor
        }
        dropStrokeLayer.strokeColor = resolved
    }

    /// Resolve the completion divider's `separatorColor` against the current
    /// appearance — `CALayer.backgroundColor` doesn't auto-flip on a dark/light
    /// change (R14), so re-resolve it in `viewDidChangeEffectiveAppearance`.
    private func applyCompletionDividerColor() {
        var resolved: CGColor = NSColor.separatorColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.separatorColor.cgColor
        }
        completionDivider.layer?.backgroundColor = resolved
    }

    /// Resolve the strip divider's `separatorColor` against the current
    /// appearance (R14 — `CALayer.backgroundColor` freezes on a dark/light flip).
    private func applyStripDividerColor() {
        var resolved: CGColor = NSColor.separatorColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.separatorColor.cgColor
        }
        stripDivider.layer?.backgroundColor = resolved
    }

    /// Fired when the view moves into a non-nil window — the controller uses
    /// this to drive window-gated autofocus from a guaranteed hook, since a
    /// child VC added after its parent already appeared may never get a fresh
    /// `viewDidAppear` (plan §4.1-5).
    var onDidMoveToWindow: (() -> Void)?

    /// Fired from `relayout()` whenever the bar's published intrinsic HEIGHT
    /// changes (text grow/shrink, attachment band, completion popup). The
    /// regime-B host (`RestingBarContainerView`) wires this to
    /// `invalidateIntrinsicContentSize()` so its own cached intrinsic height —
    /// which reads `innerContent.fittingSize.height` — is re-queried (R7). The
    /// constraint chain pins the host height too, so this is belt-and-suspenders;
    /// without it a host that relied solely on the intrinsic-size path would
    /// keep a stale cached height after text growth.
    var onIntrinsicHeightChanged: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onDidMoveToWindow?() }
    }

    // MARK: - Layout / scrim-cutout reporting (plan §4.1-2)

    override func layout() {
        super.layout()

        // Drop stroke path follows the pill's rounded silhouette.
        let inset = Self.dropStrokeLineWidth / 2
        dropStrokeLayer.frame = pillSurface.frame
        dropStrokeLayer.path = CGPath(
            roundedRect: pillSurface.bounds.insetBy(dx: inset, dy: inset),
            cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil)
        applyDropStrokeColor()

        // Recompute the attach/pill cutout rects AFTER super.layout() (frames
        // settled), converted to the scrim anchor. Report from the
        // bottom-anchored subviews so they're independent of any popup that
        // grows the pill upward (the attach/pill don't move when it opens).
        reportScrimRects()
    }

    private func reportScrimRects() {
        guard let anchor = scrimAnchorView else { return }
        let attachRect = attachButton.convert(attachButton.bounds, to: anchor)
        // The pill's cutout is its BOTTOM text row, not the whole grown pill:
        // a RoundedRectangle the height of the bottom 32pt row anchored to the
        // pill's bottom edge, so the popup growing up never moves the cutout.
        let pillFull = pillSurface.convert(pillSurface.bounds, to: anchor)
        let rowHeight = Self.pillMinHeight
        // In the anchor's (non-flipped window) space, "bottom" is min-Y; the
        // cutout is the bottom `rowHeight` band of the pill.
        let pillRow = CGRect(
            x: pillFull.minX, y: pillFull.minY,
            width: pillFull.width, height: min(rowHeight, pillFull.height))

        if !attachRect.equalTo(lastReportedAttachRect) {
            lastReportedAttachRect = attachRect
            onAttachRect?(attachRect)
        }
        if !pillRow.equalTo(lastReportedPillRect) {
            lastReportedPillRect = pillRow
            onPillRect?(pillRow)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyDropStrokeColor()
        applyCompletionDividerColor()
        applyStripDividerColor()
        CATransaction.commit()
    }

    // MARK: - NSDraggingDestination (plan §4.1-9, §4.7-1)

    /// Whether `sender`'s pasteboard advertises at least one accepted type.
    private func canAcceptDrag(_ sender: NSDraggingInfo) -> Bool {
        guard let types = sender.draggingPasteboard.types else { return false }
        return types.contains { Self.acceptedDragPasteboardTypes.contains($0) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard canAcceptDrag(sender) else { return [] }
        onDropTargetedChanged?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAcceptDrag(sender) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDropTargetedChanged?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDropTargetedChanged?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        canAcceptDrag(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { onDropTargetedChanged?(false) }
        // NSDraggingInfo exposes an NSPasteboard, not [NSItemProvider]; the
        // verbatim `loadAsURL` / `loadAsImageData` loaders take NSItemProvider.
        // Reconstruct providers from the dragging pasteboard so the loaders stay
        // byte-for-byte unchanged (R: screenshot-HUD public.png-only drags would
        // silently drop otherwise). `pasteboardItems` → one provider per item.
        let providers: [NSItemProvider] =
            sender.draggingPasteboard.pasteboardItems?.map { item in
                let provider = NSItemProvider()
                for type in item.types {
                    provider.registerDataRepresentation(
                        forTypeIdentifier: type.rawValue, visibility: .all
                    ) { completion in
                        completion(item.data(forType: type), nil)
                        return nil
                    }
                }
                return provider
            } ?? []
        return onPerformDrop?(providers) ?? false
    }
}

/// A top-left-origin (flipped) container so subviews lay out from the top,
/// matching SwiftUI's top-down stack order inside the pill.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    nonisolated deinit {}
}
