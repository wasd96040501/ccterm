import AppKit

/// The fixed vocabulary of row content a `TranscriptView` can display.
///
/// Row height is specialized per case rather than asked of the data source —
/// there is no `heightOfRow` callback. `markdown`, `userMessage`, and `image`
/// rows are self-sizing: the view measures them against its current layout
/// width. A `view` row is fixed at the caller-supplied height until the
/// caller invalidates it (see `view(_:height:)`).
public enum TranscriptRowContent {

    /// One complete markdown document rendered as a single row.
    ///
    /// The raw markdown source is handed over whole; the view owns parsing
    /// and typesetting, and never splits one document across multiple rows.
    case markdown(String)

    /// A message authored by the user.
    case userMessage(String)

    /// A bitmap image, aspect-fit to the transcript's layout width.
    case image(NSImage)

    /// A caller-owned view embedded at a fixed height.
    ///
    /// The embedded view is adopted into the row at exactly `height` points
    /// and is never measured by the transcript. When the required height
    /// changes, call `TranscriptView.noteHeightOfRows(withIndexesChanged:)`;
    /// the row's content is then re-queried from the data source and the
    /// fresh height takes effect.
    case view(NSView, height: CGFloat)
}
