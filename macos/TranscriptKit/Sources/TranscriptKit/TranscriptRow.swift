import Foundation

/// One row as the data source describes it: which row it is, and what it holds.
///
/// Answered by `TranscriptViewDataSource.transcriptView(_:rowAt:)`, and that it
/// is **one** call rather than two is most of the point. An identity and a
/// content asked separately can disagree — a host answering the id from one
/// array and the content from another, or computing the id against an index it
/// has already moved past — and every caller here wants both: a height answer
/// needs the id to look the measurement up and the content to check it against,
/// and there are several hundred of those per layout pass. A protocol
/// requirement that nothing ever calls on its own is not a real seam, so the two
/// are one atomic answer and the disagreement is unrepresentable (§4).
///
/// `NSTableViewDataSource` splits it the same way — `tableView(_:objectValueFor:row:)`
/// hands over the row's datum in one call — so this is §1 rather than a
/// deviation from it.
///
/// ## Why the identity is the host's
///
/// The cache behind the transcript is keyed on `id`. It could have been keyed on
/// the row number, and was: an array where `entries[i]` is row *i*'s, spliced in
/// lockstep with every `insertRows` / `removeRows`, where a single missed shift
/// showed up as a row rendering its neighbour's content long after the mutation
/// that caused it. Keying on content instead does not work either, for a reason
/// that is not about collisions: `MarkdownMemo` is the relationship between *this
/// row's last version* and *its next one*, so looking a donor up by the new text
/// can never find the generation built from the old text. A memo is a fact about
/// a row over time, and the only party that knows a row is the same row is the
/// host.
public struct TranscriptRow: Equatable, Sendable {

    /// A row's identity: whatever the host already uses to tell its rows apart.
    ///
    /// Type-erased rather than generic. `TranscriptView` could take the identity
    /// as a type parameter the way `NSTableViewDiffableDataSource` does — but
    /// that is a separate adapter object, whereas this is the view itself, so
    /// the parameter would spread to both protocols and to every
    /// `weak var transcript: TranscriptView?` a host writes. One dynamic
    /// dispatch per lookup is the cheaper side of that trade.
    ///
    /// ## `@unchecked`, and why it is a proof rather than a promise
    ///
    /// `AnyHashable`'s `Sendable` conformance is not merely absent — the
    /// standard library marks it `@available(*, unavailable)`, because the value
    /// inside the box may be anything at all. This wrapper is `Sendable` anyway,
    /// and the reason is the initialiser: the only way a value gets into `value`
    /// is through an `init` constrained to `Hashable & Sendable`, and `value` is
    /// `private`. So "the box holds something sendable" is enforced by the
    /// compiler at every construction site rather than asserted in a comment —
    /// which is a stronger footing than the `@unchecked` conformances elsewhere
    /// in this package, where the argument is that a type is immutable after
    /// construction.
    ///
    /// It has to be sendable, and not only for tidiness. `prepareRows(_:)` sends
    /// a batch of rows to a background task and gets measurements back; if the
    /// identity could not cross, the batch would have to be taken apart on the
    /// main actor and reassembled by position afterwards — which is precisely
    /// the positional pairing this whole change exists to delete.
    public struct ID: Hashable, @unchecked Sendable {

        private let value: AnyHashable

        public init<Identifier: Hashable & Sendable>(_ id: Identifier) {
            value = AnyHashable(id)
        }

        /// Re-wrapping is the identity function, not a second box.
        ///
        /// Without this, `ID(anID)` would satisfy the constraint above and box an
        /// `ID` inside an `AnyHashable`. The result is self-consistent — equal to
        /// other doubly-wrapped copies and to nothing else — so the failure is
        /// not a crash but a lookup that silently never hits.
        public init(_ id: ID) {
            self = id
        }
    }

    public let id: ID

    public let content: TranscriptRowContent

    /// Takes the host's own identifier — a `UUID`, a database row id, a message
    /// number — and wraps it, so nothing on the host's side has to name `ID`.
    ///
    /// **Stable across the row's life, and distinct between rows.** A host that
    /// mints a fresh identifier per streaming frame, or hands two rows the same
    /// one, gets a transcript that renders correctly and re-typesets everything
    /// it could have reused. That failure is silent by construction — the
    /// measurements are all valid, there are just none to find — which is why it
    /// is stated here rather than asserted: an assertion would have to compare
    /// every row's identity against every other on every pass, and the symptom it
    /// would catch is slowness rather than wrongness.
    public init<Identifier: Hashable & Sendable>(id: Identifier, content: TranscriptRowContent) {
        self.id = ID(id)
        self.content = content
    }

    public init(id: ID, content: TranscriptRowContent) {
        self.id = id
        self.content = content
    }
}
