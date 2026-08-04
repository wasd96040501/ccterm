import Foundation

/// A link found at an index: where it goes, and which positions it covers.
///
/// **A range, not a rectangle.** The renderer this replaces kept a parallel
/// `[LinkHit]` per layout, each with its own frame, and every enclosing container
/// had to re-project all of them by hand — a quote's indent, a list's marker
/// column, a table's cell origin, each applied at a different call site. A range
/// costs none of that: it is in the same flat index space a selection's endpoints
/// are in, so `rects(from:to:)` — already correct in every container, already the
/// thing a selection band is drawn from — turns it into geometry at the moment
/// someone needs geometry. Nothing is stored pre-projected, so nothing gets out
/// of step.
///
/// **The range is why this type exists at all.** A query that *finds* a place has
/// to hand back that place; one that returns only what it found leaves the caller
/// holding something it cannot address. That was the shape of the version this
/// replaces — a bare destination — and it read as though it obeyed the rules only
/// because it had thrown away the one thing that needed translating, which left
/// every container forwarding it with nothing to do.
///
/// The `url` is a **payload** rather than a coordinate: it means the same thing to
/// every block on the way up, so it rides through each container untouched, the
/// way the string from `text(from:to:)` does. Only `range` is lifted, and only
/// through `lifted(by:)`.
///
/// Two fields, and it stays two: what a hover *shows* and what a click *does* are
/// the host's, reached through `TranscriptViewDelegate`. This says where a link is
/// and where it points, and nothing about what to do about it.
/// `Equatable` so that "is the pointer still on the link it was on" is one
/// comparison. Both fields count: two adjacent links to the same page are the
/// same `url` and different runs, and a highlight that stayed put across the
/// boundary between them would be highlighting the wrong words.
struct InlineLink: Equatable {

    /// Where an activatable run leads.
    ///
    /// **Why this is an enum rather than a `URL`.** Everything `BlockView` does
    /// with a link — the band that fades in under it, the pointing hand, the rule
    /// that a press is a click only if it neither dragged nor selected — is about
    /// *an activatable run*, and none of it looks at the destination. A second
    /// kind of run that wanted all of that and had no address would otherwise
    /// have to bring a parallel copy of it, keyed on its own attribute, with its
    /// own hover state and its own idea of what a click is. One more case here
    /// costs a `switch` at the one place that cares which it is.
    ///
    /// `CodeBlock` predicted this shape from the other direction — "a button is
    /// that shape with a closure where the `URL` is" — and this is the same
    /// observation with the closure left out: what a `.more` press *does* is the
    /// host's, not something the run carries.
    enum Destination: Equatable {

        case url(URL)

        /// The part of a truncated message that is not on screen. Reported by
        /// `UserMessage`, which draws the run that carries it.
        case more
    }

    let destination: Destination

    /// The positions this link covers, in the index space of whichever block was
    /// asked. Lifted by each container on the way up, so what reaches the top is
    /// in the row's space — the same space a selection's endpoints are in, which
    /// is what lets one `rects(from:to:)` serve both.
    let range: Range<Int>

    init(destination: Destination, range: Range<Int>) {
        self.destination = destination
        self.range = range
    }

    /// The common case, spelled the way every caller but one wants it.
    init(url: URL, range: Range<Int>) {
        self.init(destination: .url(url), range: range)
    }

    /// The address this run leads to, or `nil` for a destination that has none —
    /// which is what a hover has to *show*, so the optionality belongs here
    /// rather than at each of the places that report one.
    var url: URL? {
        guard case .url(let url) = destination else { return nil }
        return url
    }
}

extension InlineLink {

    /// The same link, its range lifted into an enclosing block's index space.
    ///
    /// The counterpart of `CGRect.offsetBy` for the other dimension, and here for
    /// the same reason: a container that writes the arithmetic inline is a
    /// container that can write it wrong, and there is no reason for more than one
    /// copy of two additions.
    func lifted(by base: Int) -> InlineLink {
        InlineLink(
            destination: destination,
            range: (range.lowerBound + base)..<(range.upperBound + base))
    }
}
