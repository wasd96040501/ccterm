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
public enum TranscriptRowContent {

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
    /// - **Height** is asked of every row, on-screen or not: the transcript
    ///   cannot size its scroller without summing all of them. That is
    ///   `heightOfRow` — a number, cheap, asked often.
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
