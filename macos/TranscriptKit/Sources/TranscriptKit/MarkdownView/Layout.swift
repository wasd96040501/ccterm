import AppKit

/// A recipe: content that knows how to lay itself out, once someone says how
/// wide it may be.
///
/// The width is an **input**, never a field. A layout is composed before any
/// width is known, and `measure` is the single moment one is applied — which is
/// what lets a decorator subtract its own indent from the width it was given and
/// pass the rest down, with the inner number never escaping. No caller can
/// disagree with it, because no caller ever sees it.
///
/// This is the only reason there are two protocols rather than one. The shape
/// before it had containers take *already-measured* children plus the width they
/// were supposedly measured at — two arguments the caller had to keep
/// consistent, with only a doc comment saying so.
///
/// A layout knows nothing about markdown; `MarkdownLayout` is what turns parsed
/// nodes into these. Anything else that wants to build a row composes them
/// directly.
///
/// Measuring is pure and free of main-thread state — typesetting is Core Text,
/// which is thread-safe, and colours are stored rather than resolved (they
/// resolve against the appearance current at *draw* time). So a caller may run
/// it off the main actor and hand the result back, which is why `MarkdownBlock` is
/// `Sendable`.
///
/// **Space around a block is that block's own business.** Anything wanting room
/// above or below itself puts that room in the height it measures to and draws
/// its content lower — the way `ThematicBreak` always has. It is not declared,
/// not published, and not something a container is asked to resolve: a paragraph
/// does not know whether it sits in a document, a list item or a table cell, so
/// it cannot be the one to say how far it should be from its neighbours. What a
/// container owns is `spacing` — one number, the way `NSStackView` does it.
protocol Layout {

    /// Lays this content out inside `width`.
    func measure(_ width: CGFloat) -> MarkdownBlock
}
