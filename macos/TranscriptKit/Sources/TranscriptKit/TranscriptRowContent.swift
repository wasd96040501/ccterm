import Foundation

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
/// **A plain value, and nothing more.** Foundation only: it names no block, no
/// memo and no measurement. How each case is built and measured is the row
/// cache's (`RowCache.Entry.init(measuring:width:reusing:)`), so the model a host
/// constructs carries no knowledge of the renderer behind it.
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

    /// A message authored by the user: its words, and the runs of them the bubble
    /// sets apart (`UserMessage`).
    case userMessage(UserMessage)

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
        case .markdown(let source): return source
        case .userMessage(let message): return message.text
        case .view: return nil
        }
    }
}
