import AppKit

/// AppKit replacement for `InputBarView2.thumbnailStrip` (migration plan §4.1,
/// §4.7-1) — a horizontally-scrollable `NSScrollView` of `AttachmentCardView`
/// thumbnail cards, mounted ABOVE the bottom text row inside the pill (below
/// the completion popup). The strip is a PURE RENDER of the controller's
/// `attachments` array: `reconcile(_:)` rebuilds the cards, add/remove animates
/// inside ONE `NSAnimationContext` group at `.smooth(0.35)`.
///
/// SIZING (R1): `intrinsicContentSize` is `.zero` so the inner stack / card
/// backplates can never leak a height up and pump the bar host. The strip's
/// height is the FIXED `Self.stripHeight` (= `thumbnailSize + top + bottom = 64`)
/// `@required` constraint; the bar reserves that height via
/// `extraPillContentHeight` so the pill grows up to contain it. The strip's
/// presence (empty ↔ non-empty) is the controller's `relayout()` job, not an
/// intrinsic leak.
final class AttachmentStripView: NSView {

    // MARK: - Constants (verbatim from InputBarView2.swift)

    /// `thumbnailSize = 48` (InputBarView2.swift:30).
    static let thumbnailSize: CGFloat = 48
    /// `thumbnailSpacing = 8` (InputBarView2.swift:31) — HStack spacing.
    static let thumbnailSpacing: CGFloat = 8
    /// `.padding(.vertical, thumbnailTopPadding)` = 8 (InputBarView2.swift:32-33,256).
    static let thumbnailTopPadding: CGFloat = 8
    static let thumbnailBottomPadding: CGFloat = 8
    /// `.padding(.horizontal, thumbnailHorizontalPadding)` = 12
    /// (InputBarView2.swift:34,257).
    static let thumbnailHorizontalPadding: CGFloat = 12
    /// `.frame(maxHeight: thumbnailSize + thumbnailTopPadding + thumbnailBottomPadding)`
    /// = 48 + 8 + 8 = 64 (InputBarView2.swift:260).
    static let stripHeight: CGFloat = thumbnailSize + thumbnailTopPadding + thumbnailBottomPadding
    /// `.smooth(duration: 0.35)` add/remove animation (InputBarView2.swift:36,152).
    static let animationDuration: TimeInterval = 0.35

    // MARK: - Callbacks

    /// Fired with the attachment id when its card's remove-X chip is clicked.
    /// The controller removes by id and re-renders.
    var onRemove: ((UUID) -> Void)?
    /// Fired with the tapped IMAGE card's thumbnail. Routes through the
    /// controller's owned `ImagePreviewPresenter` (§4.7-1) — file cards have no
    /// preview tap.
    var onImageTapped: ((NSImage) -> Void)?

    // MARK: - Subviews

    private let scrollView = NSScrollView()
    /// Horizontal stack of cards; flipped so it lays out left-to-right from
    /// the leading edge (the default NSStackView geometry already does that —
    /// flipped only governs vertical origin, harmless here).
    private let cardStack = NSStackView()

    /// The cards currently arranged — one per attachment, in order. Exposed
    /// read-only so tests can assert card count / per-card frames without
    /// reaching into the stack.
    ///
    /// TEST-OBSERVATION GETTER (read-only): `private(set)` — tests read the
    /// arranged-card count + geometry; production never reads it (matches the
    /// `CompletionPopupView.rowViews` / `GlassBackgroundView` precedent).
    private(set) var cardViews: [AttachmentCardView] = []

    private var heightConstraint: NSLayoutConstraint!

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        assemble()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    nonisolated deinit {}

    private func assemble() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = false
        // `.scrollIndicators(.never)` → no horizontal scroller chrome; overlay
        // style + autohide so any transient scroller doesn't reserve layout.
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.scrollerInsets = NSEdgeInsetsZero

        cardStack.orientation = .horizontal
        cardStack.spacing = Self.thumbnailSpacing
        cardStack.alignment = .centerY
        cardStack.distribution = .fill
        // Edge insets reproduce the SwiftUI `.padding(.vertical, 8)` +
        // `.padding(.horizontal, 12)` on the HStack (InputBarView2.swift:256-257).
        cardStack.edgeInsets = NSEdgeInsets(
            top: Self.thumbnailTopPadding, left: Self.thumbnailHorizontalPadding,
            bottom: Self.thumbnailBottomPadding, right: Self.thumbnailHorizontalPadding)
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = cardStack
        addSubview(scrollView)

        heightConstraint = heightAnchor.constraint(equalToConstant: Self.stripHeight)
        heightConstraint.priority = .required
        heightConstraint.isActive = true

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            // The card stack is taller than the row content only via its own
            // card heights; pin its height to the strip so cards center.
            cardStack.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor),
        ])
    }

    // MARK: - Sizing (R1 — never leak a height up)

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    // MARK: - Reconcile (imperative, driven by the controller)

    /// Rebuild the card stack to match `attachments`. Pure render: removes
    /// cards whose attachment is gone, inserts cards for new attachments, in
    /// order. The bar's grow/shrink animation is owned by `InputBarView`
    /// (`relayout(animated:)`); here we only rebuild the arranged cards.
    func reconcile(_ attachments: [Attachment]) {
        // Tear down + rebuild from scratch — the card set is tiny (≤ a handful
        // typically) and each card decodes its thumbnail once at attach time
        // (held on the Attachment), so a full rebuild is cheap and avoids a
        // diff. Cards' hover state is per-instance, so a rebuild resets hover —
        // acceptable (a strip rebuild only happens on add/remove, when the
        // cursor isn't tracking a stale card).
        for card in cardViews {
            cardStack.removeArrangedSubview(card)
            card.removeFromSuperview()
        }
        cardViews.removeAll(keepingCapacity: true)

        for attachment in attachments {
            let card = AttachmentCardView(attachment: attachment)
            card.onRemove = { [weak self] in self?.onRemove?(attachment.id) }
            if case .image = attachment.kind {
                card.onTapped = { [weak self] in
                    self?.onImageTapped?(attachment.thumbnail)
                }
            }
            cardStack.addArrangedSubview(card)
            cardViews.append(card)
        }
        needsLayout = true
    }
}
