import Foundation

/// A link found under a point: where it goes.
///
/// Deliberately carries **no rectangle**. The renderer this replaces kept a
/// parallel `[LinkHit]` per layout, each with its own frame, and every enclosing
/// container had to re-project all of them by hand — a quote's indent, a list's
/// marker column, a table's cell origin, each applied at a different call site.
/// Here the question is asked at a point instead, and containers answer it the
/// same way they already answer `index(at:)`: subtract their own offset and pass
/// it down. Nothing accumulates, so nothing gets out of step.
///
/// One field, and it stays one: what a hover *shows* and what a click *does* are
/// the host's, reached through `TranscriptViewDelegate`. This says where the
/// pointer is, and nothing about what to do about it.
struct InlineLink {

    let url: URL
}
