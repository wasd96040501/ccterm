import AppKit

/// What a `BlockView` reports about its links and its context menu, to the
/// transcript that built it.
///
/// Internal: the host's surface is `TranscriptViewDelegate`, and these calls
/// cross no such boundary — `TranscriptView` creates every `BlockView` itself and
/// is the one delegate any of them has, set once at creation. Every call hands the
/// view back rather than a row index, because a row's index moves under a view
/// that is standing still; the transcript resolves the current one when it is
/// told.
@MainActor
protocol BlockViewDelegate: AnyObject {

    /// A link in this row was clicked.
    ///
    /// The whole run goes over, not its address: what the view knows is *that an
    /// activatable run was clicked*, and which kind it was is a question only the
    /// side holding the host's delegate can act on. See `InlineLink.Destination`.
    func blockView(_ view: BlockView, didActivate link: InlineLink)

    /// The link under the pointer changed; `nil` on leaving one.
    ///
    /// What the hover *says* is still the host's — an address in a label, a
    /// preview, nothing at all. What it *looks like on the run* is not, and cannot
    /// be: only the view knows which rectangles a run occupies. So the band under
    /// the words is drawn there and the address is reported here, which is the
    /// line between the two halves.
    ///
    /// Fires only when the answer changes, so each call is an instruction rather
    /// than a sample. `point` is in the view's coordinates.
    func blockView(_ view: BlockView, didHover url: URL?, at point: CGPoint)

    /// This row was right-clicked, and `menu` is the one **this package** would
    /// show: the commands it implements itself, and nothing else. What comes back
    /// is what gets displayed — the same menu with items added, a different menu,
    /// or `nil` for none at all.
    ///
    /// Handing over a proposed menu rather than asking whether to show one is
    /// what lets the two sets of commands compose. Copy depends on a selection
    /// nobody outside the transcript can see, so it cannot be the host's to build;
    /// Quote, Retry and the rest depend on a model this package will never know
    /// about, so they cannot be the view's. A proposal that comes back edited is
    /// the only shape where each side writes the half it can.
    ///
    /// The menu is built fresh per click for that reason too — an accumulating
    /// shared instance would grow another copy of the host's items every time the
    /// reader right-clicked. That is the one place this deviates from
    /// `NSView.defaultMenu`, whose class-property shape hands the same object to
    /// everyone.
    ///
    /// The event goes over too, because what the menu acts on is decided on the
    /// way: a right-click outside the selection takes the word under the pointer,
    /// and the selection is the transcript's to change.
    func blockView(_ view: BlockView, menu: NSMenu, for event: NSEvent) -> NSMenu?
}
