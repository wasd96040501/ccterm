import AppKit

extension RowCache {

    /// One row's answer, and — while it is resident — everything needed to produce
    /// the next one cheaply.
    ///
    /// `Sendable`, because this is also what a background task produces: measuring
    /// off the main actor and measuring on it end at the same value, so there is
    /// one shape rather than a "prepared" one and a real one. See
    /// `TranscriptView.prepareRows(_:)`.
    struct Entry: Sendable {

        /// What this was built from — what the entry is valid against. The whole
        /// content rather than its text, for the reason on `RowCache`.
        var content: TranscriptRowContent

        var measuredWidth: CGFloat

        /// The height `tree` measured to at `measuredWidth` — kept when the tree is
        /// not, which is what lets the table be answered about every row while only
        /// a few of them are typeset.
        var height: CGFloat

        /// The recipe and the typeset lines, or `nil` once evicted.
        var tree: Tree?

        /// A tree: how the row rebuilds when its content moves, and what it drew.
        struct Tree: Sendable {
            var body: Body
            var measured: MeasuredBlock
        }

        init(content: TranscriptRowContent, body: Body, measured: MeasuredBlock, measuredWidth: CGFloat) {
            self.content = content
            self.measuredWidth = measuredWidth
            self.height = measured.size.height
            self.tree = Tree(body: body, measured: measured)
        }

        /// `content` built and measured at `width`, taking whatever `previous`
        /// still has to offer. `nil` for `.view`, which is the host's to draw and
        /// the host's to measure.
        ///
        /// **The one place a content case names a recipe**, and it lives with the
        /// cache rather than on `TranscriptRowContent` so that the row model stays a
        /// plain value the host builds — it names no block, no memo and no
        /// measurement. Every caller comes through here: `RowCache` on the main
        /// actor with a previous entry, `PreparedRows` and the find's walk on the
        /// pool with none. One copy is the point — two answering the same question
        /// about the same row on two threads do not fail when they disagree, they
        /// show up later as a row whose height changes the first time something
        /// re-measures it, and a second copy is how one comes to be missing a case.
        ///
        /// A whole `Entry`, not just its measurement: what a row costs is the
        /// recipe *and* the answer, and a caller that produced only the answer
        /// would leave the row without a donor for its next version or its next
        /// width. The note on `Body` records what that cost.
        ///
        /// ## What `previous` is for
        ///
        /// Both self-drawn cases keep something between versions, and what they
        /// keep is what differs between them — a document keeps the blocks that did
        /// not change, a bubble keeps its recipe. Passing the previous entry in,
        /// rather than having two entry points for "cold" and "warm", is what makes
        /// the cold path *literally* the warm path with nothing to take from: `nil`
        /// is not a second expression that happens to agree today.
        ///
        /// `previous` is a hint and never a truth. Its content is compared against
        /// `content` here, so an entry belonging to an older version of the row
        /// contributes its pieces and nothing else; handing over the wrong one
        /// costs a rebuild, not a wrong answer.
        ///
        /// ## Threads
        ///
        /// Pure and free of main-thread state: Core Text is thread-safe, fonts and
        /// colours are stored rather than resolved (they resolve against the
        /// appearance current at *draw* time), and nothing here consults
        /// `NSFontManager` or any other main-thread singleton. That is the property
        /// `Block` and `MeasuredBlock`'s `Sendable` conformances both rest on, and
        /// the one to preserve.
        init?(measuring content: TranscriptRowContent, width: CGFloat, reusing previous: Entry?) {
            switch content {
            case .markdown(let source):
                var memo: MarkdownMemo
                let measured: MeasuredBlock
                if case .markdown(let donor)? = previous?.body {
                    memo = donor
                    if previous?.content == content {
                        // Only the width can have moved. Equal content cannot
                        // parse into different children, so reading the source
                        // again would be work with a provably known answer: 60% of
                        // what a width change used to cost, spent recovering an
                        // order the memo can simply keep.
                        measured = memo.remeasure(width: width)
                    } else {
                        // The streaming path. The source has to be read, and
                        // `MarkdownMemo` is what keeps that affordable — the donor
                        // is the previous version, and only the blocks that
                        // actually changed are laid out.
                        measured = memo.measure(source, width: width)
                    }
                } else {
                    // Nothing to take from: a row nobody has measured, one that
                    // was a bubble until now, or a background task preparing rows
                    // that do not exist yet. Not
                    // `MarkdownBlockBuilder.make(source).measure`, though it
                    // produces the identical stack — routing through the memo is
                    // what makes this the branch above with an empty donor.
                    (memo, measured) = MarkdownMemo.measured(source, width: width)
                }
                self.init(
                    content: content, body: .markdown(memo), measured: measured,
                    measuredWidth: width)

            case .userMessage(let text):
                // One block, and it does not depend on the width — so a previous
                // one is reused whole and only the measure re-runs. A text that
                // moved has nothing reusable in it; the bubble is rebuilt.
                let block: Block
                if case .block(let donor)? = previous?.body, previous?.content == content {
                    block = donor
                } else {
                    block = UserMessage(text)
                }
                self.init(
                    content: content, body: .block(block), measured: block.measure(width),
                    measuredWidth: width)

            case .view:
                return nil
            }
        }

        var body: Body? { tree?.body }
        var measured: MeasuredBlock? { tree?.measured }

        /// This entry with only its height left.
        var evicted: Entry {
            var entry = self
            entry.tree = nil
            return entry
        }

        /// This entry laid out at a different width, from what it already holds.
        ///
        /// **While resident: no source, and therefore no parse and no shaping** —
        /// the recipe is the whole input. That is what makes this the thing a
        /// background task can be handed: `MeasuredBlock`, `Block` and
        /// `MarkdownMemo` are all `Sendable`, and none of this touches main-thread
        /// state.
        ///
        /// **Evicted, it is rebuilt from the content** — parse and shape as well —
        /// and comes back evicted again, so correcting a height does not quietly
        /// make every row resident. Both happen here, on whatever thread calls
        /// this, which is the pool: the tree is released where it was built.
        ///
        /// The content is carried through untouched. It is not an input to the
        /// work — it is what the answer will be checked against when it lands, by
        /// whoever files it.
        func remeasured(at width: CGFloat) -> Entry {
            switch tree?.body {
            case .markdown(var memo)?:
                let measured = memo.remeasure(width: width)
                return Entry(
                    content: content, body: .markdown(memo), measured: measured,
                    measuredWidth: width)

            case .block(let block)?:
                return Entry(
                    content: content, body: .block(block), measured: block.measure(width),
                    measuredWidth: width)

            case nil:
                guard let rebuilt = Entry(measuring: content, width: width, reusing: nil) else {
                    return self
                }
                return rebuilt.evicted
            }
        }
    }

    /// What an entry keeps between versions of its content, which is the one thing
    /// that differs between the self-drawn cases.
    ///
    /// A document is many blocks and grows a token at a time, so what is worth
    /// keeping is the blocks that did not change. A user's bubble is one block and
    /// arrives whole, so what is worth keeping is the recipe — which costs nothing
    /// on a width change and is simply rebuilt when the text moves. Modelling that
    /// as an enum rather than as two caches keeps one store and one answer to "has
    /// this row's content moved".
    ///
    /// **Two cases, and there was briefly a third.** A `seeded` case carried a
    /// measurement with no recipe behind it, for entries that had crossed an actor
    /// boundary back when `Block` was not `Sendable`. It was not a third way of
    /// keeping something — it was *nothing kept*, which is a hole rather than a
    /// case, and it cost what a hole here costs: every row that arrived from a
    /// background task re-parsed **and re-shaped** on the first width change,
    /// instead of only re-breaking its lines. On a ten-thousand-row transcript
    /// that is the difference between a resize and a freeze. Nine
    /// `@unchecked Sendable` annotations retired it, in nine files that each
    /// already carried the identical annotation one type below.
    ///
    /// An evicted entry (`Entry.tree == nil`) is that hole again, on purpose and
    /// with the difference that made the first one a freeze removed: its rebuild
    /// runs on the pool (`Entry.remeasured(at:)`), and only for the rows that did
    /// not fit in `residentBudget` rather than for every row that arrived prepared.
    enum Body: Sendable {
        case markdown(MarkdownMemo)
        case block(Block)
    }
}
