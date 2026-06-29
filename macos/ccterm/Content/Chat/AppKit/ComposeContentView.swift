import AppKit

/// The New Session compose surface root, pure AppKit (migration plan §4.6).
/// Replaces the SwiftUI `ComposeSessionView` (`ZStack { DotGridBackground();
/// NewSessionConfigurator … }`): a `DotGridView` backdrop pinned 4-edge with the
/// `NewSessionConfiguratorViewController`'s card centered on top, sized to the
/// card's `idealWidth × height` band. The card's WIDTH shrinks-to-fit a narrow
/// pane (the reachable clipping case at the 680pt detail-pane minimum); its
/// HEIGHT holds the ideal and overflows centered on a short pane (see the
/// width-vs-height asymmetry in `init`).
///
/// ## Regime-A no-collapse (plan R1)
///
/// This view IS the `ComposeSessionViewController`'s fill-the-pane content,
/// pinned 4-edge by the VC. A 4-edge-pinned root publishes no `fittingSize`
/// **only if** its subtree's `@required` min-size constraints don't propagate
/// up. The card is pinned by `centerX/centerY` ONLY (no edge pin to the root),
/// so the configurator card's internal `@required` content min stays inside the
/// card and never forces the root taller; the card's ideal size is a self-`==`
/// constraint placed just below `fittingSizeCompression` (50), honored in the
/// live solve but yielded to in `fittingSize` (so the VC publishes
/// `fittingSize.height ≈ 0`). This keeps
/// `AppKitSwiftUIBoundaryTests.testComposeAndDraftLandingFillPanesDoNotCollapse`
/// green.
@MainActor
final class ComposeContentView: NSView {
    nonisolated deinit {}

    private let grid = DotGridView()

    /// The configurator card (its view is pinned centered here). Held so the
    /// caller can drive folder/recents wiring through the VC.
    let configurator: NewSessionConfiguratorViewController

    init(configurator: NewSessionConfiguratorViewController) {
        self.configurator = configurator
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)

        configurator.loadViewIfNeeded()
        let card = configurator.view
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        // Card band — sized to its ideal `idealWidth × height`, capped to the
        // Card band — sized to its ideal `idealWidth × height`. The WIDTH is
        // additionally capped to the pane so the card SHRINKS-TO-FIT
        // horizontally on a narrow detail pane (the dominant, reachable clipping
        // case: `MainSplitViewController.detailItem.minimumThickness` lets the
        // detail pane reach 680pt — far under the 960 card — at the supported
        // minimum, so without this the Projects column / bar were clipped). The
        // *pull-to-ideal* constraints sit JUST BELOW `fittingSizeCompression`
        // (50) so `fittingSize` collapses them to ≈ 0 (plan R1).
        //
        // ## Why width couples to the pane but height does NOT
        //
        // The leak risk is an `@required` content min in the COUPLED axis
        // propagating up through the pane-relative constraint into this
        // 4-edge-pinned root's `fittingSize`:
        //   - WIDTH: the configurator card has no binding `@required` width
        //     content min (its two columns compress horizontally), and width
        //     does not feed the `fittingSize.height ≈ 0` gate anyway, so a
        //     `card.width <= self.width - 2*inset` inequality is leak-safe — the
        //     same coupling `DraftLandingContentView` already uses. ✔
        //   - HEIGHT: the card's vertical content has a ~262pt `@required` min,
        //     and a `card.height <= self.height - 2*inset` inequality DOES leak
        //     it up — the `fittingSize.height` gate measured 262 with that cap
        //     present. So height is capped ONLY by the fixed `idealHeight`
        //     constant (no pane coupling). The card stays pinned centerX/centerY
        //     only, so on a pane SHORTER than `idealHeight` + 2*inset it
        //     overflows top/bottom CENTERED rather than shrinking — matching the
        //     SwiftUI `minHeight 360` refuse-to-shrink intent + the window's
        //     540pt min-height invariant. (Replicating the SwiftUI vertical
        //     shrink leak-free would require lowering the card's internal
        //     vertical content-min priority, which lives in the
        //     `NewSessionConfigurator…` files outside this change.)
        // The ideal size is a self-`==` at priority 49 — honored in the live
        // solve (which runs no `fittingSizeCompression`) but yielded to in
        // `fittingSize` (compression at 50 wins), collapsing the root to ≈ 0.
        let idealPriority = NSLayoutConstraint.Priority(
            NSLayoutConstraint.Priority.fittingSizeCompression.rawValue - 1)
        let typeMax = NewSessionConfiguratorViewController.maxWidth
        let typeIdeal = NewSessionConfiguratorViewController.idealWidth
        let cardHeight = NewSessionConfiguratorViewController.height
        let hInset = ChatSessionViewController.detailHorizontalInset

        let widthIdeal = card.widthAnchor.constraint(equalToConstant: typeIdeal)
        widthIdeal.priority = idealPriority
        let heightIdeal = card.heightAnchor.constraint(equalToConstant: cardHeight)
        heightIdeal.priority = idealPriority

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),

            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Fixed type caps: never exceed the ideal `maxWidth` / `height`.
            card.widthAnchor.constraint(lessThanOrEqualToConstant: typeMax),
            card.heightAnchor.constraint(lessThanOrEqualToConstant: cardHeight),
            // Pane-coupled WIDTH cap (REQUIRED `<=`, the shrink-to-fit fix): on a
            // pane narrower than the ideal card + 2*inset, the card shrinks to
            // keep the 20pt side margins instead of overflowing. Inequalities
            // only bound downward → leak-safe (no `fittingSize` propagation).
            card.widthAnchor.constraint(
                lessThanOrEqualTo: widthAnchor, constant: -2 * hInset),
            widthIdeal, heightIdeal,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Regime-A: publish `.zero` so the card's min-size band never leaks up into
    /// the VC's 4-edge-pinned `fittingSize.height` and collapses the window
    /// (plan R1, `AppKitSwiftUIBoundaryTests`).
    override var intrinsicContentSize: NSSize { .zero }
}
