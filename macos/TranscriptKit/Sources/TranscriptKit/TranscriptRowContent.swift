import AppKit

/// The fixed vocabulary of row content a `TranscriptView` can display.
///
/// A case says **who draws the row**, and little else. The first two carry
/// their payload with them and are drawn by the transcript itself; `view`
/// says "this one is yours", and the host answers two further data source
/// calls to size and supply it.
///
/// Height is specialized per case rather than asked in one uniform place.
/// `markdown` and `userMessage` are self-sizing — the transcript measures them
/// against its current content width, and re-measures them itself whenever that
/// width changes. A `view` row is sized by
/// `TranscriptViewDelegate.transcriptView(_:heightOfRow:width:)`.
///
/// **There is no image case**, and the absence is the rule rather than an
/// omission. One shipped here — `image(NSImage)` — and never grew a block
/// behind it, which is what made the argument concrete: what an image row costs
/// is decoding, a placeholder while that runs, a failure state, an original
/// that is not the copy on screen, and a press that opens something. All five
/// are the host's, and the sixth — fitting a bitmap to the content width — is
/// one line of arithmetic on either side of the seam. So a picture is a `view`
/// row, the way §4 says every richer thing is, and `TranscriptMedia`'s
/// `ImageGridView` is one host's answer rather than this package's.
///
/// `Sendable` because every payload is a `String` and because
/// `TranscriptView.prepareRows(_:)` carries a batch of these to a background
/// task to measure. Nothing here is reference type, so the conformance costs
/// no `unchecked`.
///
/// `Equatable` because that is what a cached measurement is valid against:
/// `RowCache` believes an entry only as far as its content still matches what is
/// being asked for, and **the payload alone does not answer that.** The same
/// string is a different height as a document than as a bubble — a bubble is
/// measured into three quarters of the column — so comparing sources would let a
/// measurement of one serve a row of the other, and the entry that writes is
/// internally consistent, so nothing downstream ever objects: a row permanently
/// the wrong height rather than a wasted re-measure. Comparing the whole value
/// costs the same: the case is checked first, and equal payloads in the ordinary
/// case are two `String`s sharing storage.
public enum TranscriptRowContent: Sendable, Equatable {

    /// One complete markdown document rendered as a single row.
    ///
    /// The raw markdown source is handed over whole; the view owns parsing
    /// and typesetting, and never splits one document across multiple rows.
    case markdown(String)

    /// A message authored by the user.
    case userMessage(String)

    /// A row drawn by a host-supplied `NSView`.
    ///
    /// The case is deliberately payload-free — it carries neither a view
    /// instance nor a height, because those two are needed at different
    /// moments and at wildly different frequencies (both are the delegate's
    /// to answer):
    ///
    /// - **Height** is asked of far more rows than are on screen — a few hundred
    ///   at a time, growing as the reader moves around, since `NSTableView`
    ///   measures a working set and extrapolates its scroll range from that
    ///   sample. That is `heightOfRow` — a number, cheap, asked often.
    /// - **The view** is asked only for rows entering the viewport. That is
    ///   `viewForRow`, where the host recycles an instance through
    ///   `TranscriptView.makeView(withIdentifier:make:)` and fills it in. A
    ///   screenful of calls, regardless of how long the transcript is.
    ///
    /// Carrying an instance in the payload would collapse the two: answering
    /// "how tall is row 8000" would mean building row 8000's view. Ten
    /// thousand rows would mean ten thousand live views, and recycling — the
    /// whole reason a row-based view beats a stack of everything — would
    /// never engage.
    case view
}

extension TranscriptRowContent {

    /// The text a self-drawn row's cached tree is **valid against** — `nil` for
    /// `.view`, which the transcript does not draw and therefore does not key.
    ///
    /// One accessor rather than a `switch` at each site, and the sites are far
    /// enough apart that a second copy of the mapping would drift: what a row
    /// cache entry reports as the text it was built from, and what
    /// `rebindVisibleRows(in:)` compares to decide whether a reader's selection
    /// still names the same characters. A missing case in either is a row that
    /// silently stops being re-measured.
    var source: String? {
        switch self {
        case .markdown(let source), .userMessage(let source): return source
        case .view: return nil
        }
    }

    /// This content built and measured at `width`, taking whatever `previous`
    /// still has to offer. `nil` for `.view`, which is the host's to draw and the
    /// host's to measure.
    ///
    /// **The one place a content case names a recipe**, and that is the whole
    /// point of it being here rather than at either of its callers. There were two
    /// copies once — this one, and a `switch` in `TranscriptView` that told
    /// `RowCache` how to rebuild each case — and they had to stay in step for a
    /// reason with no symptom: they answer the same question about the same row,
    /// on two threads, so a disagreement does not fail, it shows up much later as
    /// a row whose height changes the first time something re-measures it. A
    /// second copy is also how one of them comes to be missing a case: not as a
    /// build error, but as a row that quietly stops being re-measured.
    ///
    /// A whole `RowCache.Entry`, not just its measurement: what a row costs is
    /// the recipe *and* the answer, and a caller that produced only the answer
    /// would leave the row without a donor for its next version or its next
    /// width. That was a real state here once, and the note on `RowCache.Body`
    /// records what it cost.
    ///
    /// ## What `previous` is for
    ///
    /// Both self-drawn cases keep something between versions, and what they keep
    /// is what differs between them — a document keeps the blocks that did not
    /// change, a bubble keeps its recipe. Passing the previous entry in, rather
    /// than having two entry points for "cold" and "warm", is what makes the cold
    /// path *literally* the warm path with nothing to take from: `nil` is not a
    /// second expression that happens to agree today.
    ///
    /// `previous` is a hint and never a truth. Its content is compared against
    /// `self` here, so an entry belonging to an older version of the row
    /// contributes its pieces and nothing else; handing over the wrong one costs a
    /// rebuild, not a wrong answer.
    ///
    /// ## Threads
    ///
    /// Pure and free of main-thread state: Core Text is thread-safe, fonts and
    /// colours are stored rather than resolved (they resolve against the
    /// appearance current at *draw* time), and nothing here consults
    /// `NSFontManager` or any other main-thread singleton. That is the property
    /// `Block` and `MeasuredBlock`'s `Sendable` conformances both rest on, and
    /// the one to preserve. `TranscriptView.prepareRows(_:)` calls this on a
    /// background task with no previous entry to take from; `RowCache` calls it on
    /// the main actor with one.
    func entry(width: CGFloat, reusing previous: RowCache.Entry?) -> RowCache.Entry? {
        switch self {
        case .markdown(let source):
            var memo: MarkdownMemo
            let measured: MeasuredBlock
            if case .markdown(let donor)? = previous?.body {
                memo = donor
                if previous?.content == self {
                    // Only the width can have moved. Equal content cannot parse
                    // into different children, so reading the source again would
                    // be work with a provably known answer: 60% of what a width
                    // change used to cost, spent recovering an order the memo can
                    // simply keep.
                    measured = memo.remeasure(width: width)
                } else {
                    // The streaming path. The source has to be read, and
                    // `MarkdownMemo` is what keeps that affordable — the donor is
                    // the previous version, and only the blocks that actually
                    // changed are laid out.
                    measured = memo.measure(source, width: width)
                }
            } else {
                // Nothing to take from: a row nobody has measured, one that was a
                // bubble until now, or a background task preparing rows that do
                // not exist yet. Not `MarkdownBlockBuilder.make(source).measure`,
                // though it produces the identical stack — routing through the
                // memo is what makes this the branch above with an empty donor.
                (memo, measured) = MarkdownMemo.measured(source, width: width)
            }
            return RowCache.Entry(
                content: self, body: .markdown(memo), measured: measured, measuredWidth: width)

        case .userMessage(let text):
            // One block, and it does not depend on the width — so a previous one
            // is reused whole and only the measure re-runs. A text that moved has
            // nothing reusable in it; the bubble is rebuilt.
            let block: Block
            if case .block(let donor)? = previous?.body, previous?.content == self {
                block = donor
            } else {
                block = UserMessage(text)
            }
            return RowCache.Entry(
                content: self, body: .block(block), measured: block.measure(width),
                measuredWidth: width)

        case .view:
            return nil
        }
    }
}
