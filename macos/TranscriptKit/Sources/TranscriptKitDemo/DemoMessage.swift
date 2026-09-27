import AppKit

/// One turn in the demo transcript.
struct DemoMessage {

    /// What the turn is, which is also who draws it. The first two are the
    /// transcript's — `.userMessage` and `.markdown`; the third is the demo's
    /// own `.view` row, and the reason the demo now implements `heightOfRow` and
    /// `viewForRow` where it used to implement neither.
    enum Content {
        case user(String)
        case assistant(String)

        /// Pictures the reader attached, drawn by `ImageGridView`. Addresses
        /// rather than images: the package has no picture case and will not grow
        /// one, and what a row of pictures costs — the header read, the decode,
        /// the cache, the failure — all lives on this side of the seam and all of
        /// it starts from a URL.
        case images([URL])
    }

    /// Who this turn is, for as long as it exists — what the transcript files its
    /// measurement under, through `TranscriptRow`.
    ///
    /// A `UUID` rather than the turn's index, because an index is not an identity:
    /// **Prepend 5** renumbers every row below it, and a transcript keyed on the
    /// old numbers would hand each row its neighbour's layout.
    let id: UUID

    let content: Content

    init(id: UUID = UUID(), content: Content) {
        self.id = id
        self.content = content
    }

    /// The turn's text, or `nil` for a row that has none. Only the control
    /// panel's grow buttons ask, and only about row 0.
    var text: String? {
        switch content {
        case .user(let text), .assistant(let text): return text
        case .images: return nil
        }
    }

    /// The same turn with more text on the end, or unchanged when there is no
    /// text to add to.
    ///
    /// **Keeps `id`.** This is the streaming path — one frame's growth — and a
    /// host that minted a fresh identity here would be telling the transcript that
    /// every frame is a different row. What that looks like is the reason to say
    /// it: nothing renders wrongly. Every lookup misses, so each frame re-parses
    /// and re-typesets the whole document instead of reusing the blocks that did
    /// not change, and the reader's selection is dropped sixty times a second
    /// because a row with no previous version cannot have extended it. A bug whose
    /// only symptom is that something is slower than it should be is one nobody
    /// finds by looking.
    func appending(_ suffix: String) -> DemoMessage {
        switch content {
        case .user(let text): return DemoMessage(id: id, content: .user("\(text) \(suffix)"))
        case .assistant(let text):
            return DemoMessage(id: id, content: .assistant("\(text) \(suffix)"))
        case .images: return self
        }
    }
}

extension DemoMessage {

    /// The transcript the demo opens on: a short exchange in which every
    /// assistant turn is one real markdown document.
    ///
    /// Real documents rather than generated filler, and few enough to read
    /// through, because the thing being checked is whether a *document* comes
    /// out looking like one — the vertical rhythm between a heading and the
    /// paragraph under it, a quote's bar against its glyphs, a code card's
    /// padding. Repeated lorem answers that question for one shape and hides it
    /// for every other.
    ///
    /// Between them the eight documents use every node `MarkdownIR` has: all six
    /// heading levels, ordered / unordered / task / nested lists with a start
    /// index, tight lists beside loose ones, fenced code with and without a
    /// language plus a multi-word info string and an indented block, a table
    /// carrying all four alignments and a spanned cell, nested blockquotes
    /// holding blocks of their own, thematic breaks, footnotes in all four of
    /// their states, images with alt / with title / with neither, and — in
    /// `inlineKitchenSink` — one paragraph containing every inline node at once.
    /// A shape that renders wrongly is visible on this screen; a shape missing
    /// from here is a shape nobody is looking at.
    static var script: [DemoMessage] {
        [
            .user("What shipped in 0.3?"),
            .assistant(releaseNotes),
            .user(
                "Remind me what actually happens in one runloop iteration — I keep having to "
                    + "re-derive which half of it runs my code and which half is AppKit "
                    + "flushing, and I want the long version so the bubble has something to "
                    + "wrap."),
            .assistant(runloopTick),
            .user("How do I pick between a delegate and a Combine publisher?"),
            .assistant(mechanismTable),
            .assistant(measuringARow),
            .user(pastedReport),
            .assistant(placingAnEntity),
            .assistant(shortAnswer),
            .user("Show me every list shape at once."),
            .assistant(listShapes),
            .assistant(inlineKitchenSink),
            .user("And the things that only render right by accident?"),
            .assistant(referencesAndNotes),

            // Every branch of `MosaicLayout`, in the order the algorithm reaches
            // them, because which one runs is decided by the proportions rather
            // than by the count — two pictures can go through the hand-written
            // pair rule or through the search, and only the picture's shape says
            // which. Reading them in a row is how a wrong branch is caught.
            .user("Here's what the mosaic does with one picture."),
            .images(DemoImage.group(1)),
            .user("Two of a kind — equal halves."),
            .images(DemoImage.group(2, offset: 7)),
            .user("Two that disagree — the split makes both the same height."),
            .images(DemoImage.group(2, offset: 4)),
            .user("Two where one is a 3:1 panorama, so the search runs instead."),
            .images(DemoImage.group(2, offset: 2)),
            .user("Three led by a portrait — full height on the left."),
            .images(DemoImage.group(3, offset: 5)),
            .user("Three led by a wide one — it takes the top, two share the bottom."),
            .images(DemoImage.group(3)),
            .user("Four with a wide leader over a row of three."),
            .images(DemoImage.group(4, offset: 4)),
            .user("Four with a tall leader and three stacked beside it."),
            .images(DemoImage.group(4, offset: 5)),
            .user("Five, arranged by the line-split search."),
            .images(DemoImage.group(5, offset: 4)),
            .user("And seven, which is where the search earns its keep."),
            .images(DemoImage.group(7)),
            // The two states that are not a picture: an address that resolves to
            // nothing, and a remote one whose row was laid out before anything
            // was known about it and is not re-laid-out afterwards.
            .user("And the two that are not pictures at all."),
            .images([DemoImage.missing, DemoImage.remote]),
        ]
    }

    static func user(_ text: String) -> DemoMessage {
        DemoMessage(content: .user(text))
    }

    static func assistant(_ text: String) -> DemoMessage {
        DemoMessage(content: .assistant(text))
    }

    static func images(_ urls: [URL]) -> DemoMessage {
        DemoMessage(content: .images(urls))
    }

    /// Long enough to be cut short, which is the only way to see the `More` run
    /// and the ellipsis above it — and pasted-looking, because that is how a
    /// message gets long enough for either to matter.
    ///
    /// Deliberately holding characters a markdown pass would eat — `**`,
    /// `Sources/**/*.swift`, `__init__`, a leading `#` — so that the bubble
    /// showing them verbatim is visible on screen rather than only asserted.
    fileprivate static let pastedReport = """
        Here's the whole repro, pasted from the issue — don't fix it yet, I just \
        want to know which layer it belongs to.

        Steps: open a session with ~400 rows, drag the window's right edge from \
        1400 to 700 in one motion, then let go. Somewhere in that drag the rows \
        below the fold stop agreeing with the ones on screen: the first screenful \
        re-wraps at the new width, but scrolling down lands on rows still laid out \
        for the old one, and they only correct themselves when they scroll back in. \
        It reproduces every time on the 14" display and about one time in three on \
        the external one, which makes me think it's tied to how many rows are \
        visible rather than to the width itself.

        What I've ruled out: it isn't the parse — I logged the block trees and they \
        are identical across the drag. It isn't __init__ order either; the same \
        thing happens on a transcript that was already fully loaded before the drag \
        started. I grepped Sources/**/*.swift for every noteHeightOfRows call and \
        there are three, and only one of them runs during a live resize.

        My guess is that the mid-drag pass invalidates only what's on screen — \
        which is the right call for the frame budget — and that the pass which is \
        supposed to catch up on mouse-up either doesn't run or runs against a \
        width that has already moved again. If that's it, the fix is in whoever \
        owns "the drag ended", not in the layout code, and the test would be a \
        resize that ends while a row below the fold is still stale.

        # Not urgent
        Nobody outside the team has hit it. But it's the second bug this month \
        that comes down to "invalidated the visible rows and meant to catch up \
        later", so if there's a shape that makes the catch-up impossible to \
        forget, I'd rather spend the time on that than on this one bug.
        """
}

// MARK: - The documents
//
// Raw string literals throughout: markdown's hard line break is a trailing
// backslash, which a plain literal would eat.

extension DemoMessage {

    /// Headings 1–3, a GFM task list, strikethrough, an explicit link, a bare
    /// URL, a hard line break, a thematic break.
    fileprivate static let releaseNotes = #"""
        # TranscriptKit 0.3

        The first build where an assistant turn is drawn by the package itself
        rather than handed back to the host as a `.view`.

        ## Highlights

        - [x] Two layers: a `Block` is a *recipe* that composes before any width
              is known, and `measure` is the one moment a width is applied
        - [x] Decorators wrap any layout, not parsed nodes — so a quote holds a
              code card, a list, or another quote, and never learns which
        - [x] Measuring runs off the main actor; only drawing needs it
        - [ ] Two-dimensional table selection
        - [ ] Link activation, and the copy button on a code card

        ## Breaking changes

        `TranscriptRowContent.markdown` no longer routes back through the host.
        If you were answering `heightOfRow` for assistant turns, ~~delete that
        arm~~ — it is dead code now; the transcript measures those rows itself.

        ### Upgrading

        Read the geometry notes at https://developer.apple.com/documentation/appkit
        before filing anything about row heights.\
        The [scroll-anchoring rules](https://example.com/anchoring) did not change.

        ---

        Thanks to everyone who sent a repro.
        """#

    /// A fenced block with no language, an ordered list whose items wrap, and a
    /// blockquote containing a list.
    fileprivate static let runloopTick = #"""
        ## One runloop iteration

        Most "why is this one tick off" puzzles resolve once you remember the
        order AppKit and CoreAnimation share a single iteration.

        ```
        ┌─ source phase ──────────── your code runs here ────────────┐
        │  NSEvent dispatch · DispatchQueue.main · @MainActor Tasks  │
        │  setNeedsLayout / frame writes land NOW                    │
        ├─ beforeWaiting ─────── AppKit + CoreAnimation flush ───────┤
        │  updateConstraints → layout → display                      │
        │  CATransaction implicit commit → render server             │
        └─ sleep ──── the thread blocks until the next event ────────┘
        ```

        Two consequences are load-bearing here:

        1. A source-phase scroll write needs the geometry it depends on **already
           settled**. Writing first and waiting hands you one frame at the old
           geometry, which reads as a flicker nobody can reproduce on demand.
        2. `layoutSubtreeIfNeeded()` flushes Auto Layout, and *that* triggers a
           chain of side effects which look like "not Auto Layout" —
           `NSTableView.tile()` among them, because a tile is gated on a frame
           change and Auto Layout is what changes frames.

        > Two stack-trace aliases worth memorising:
        >
        > - `__CFRUNLOOP_IS_CALLING_OUT_TO_AN_OBSERVER_CALLBACK_FUNCTION__` —
        >   you are inside a runloop observer, almost always CoreAnimation's flush.
        > - `__CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__` — source phase,
        >   draining `DispatchQueue.main`.
        """#

    /// A GFM table carrying all four column alignments.
    fileprivate static let mechanismTable = #"""
        ### Which mechanism to reach for

        Pick by cardinality and by direction — does it need to talk back?

        | Mechanism | Cardinality | Talks back | Lifecycle |
        |:----------|:-----------:|-----------:|-----------|
        | target-action | 1:1 | no | weak target |
        | delegate | 1:1 | **yes** | `weak var delegate` |
        | NotificationCenter | 1:many | no | remove the observer before `deinit` |
        | KVO | 1:many | no | `NSKeyValueObservation` alive = observing |
        | Combine `@Published` | 1:many | no | `AnyCancellable` in a `Set` |
        | closure callback | 1:1 | yes | captured — mind `[weak self]` |
        | [the docs](https://developer.apple.com/documentation/appkit "AppKit reference") ||| a link, and a cell spanning the rest |

        A table is the one shape whose selection is genuinely two-dimensional:
        dragging from *Cardinality* down two rows should take a rectangle, not a
        text range that swallows everything in between.

        The last row is a `colspan`: cmark-gfm fills the columns a spanned cell
        swallows with empty placeholders, so the grid stays rectangular and the
        row simply reads as merged — there being no vertical rules to interrupt.
        """#

    /// Fenced code with a language, twice, plus an indented block.
    fileprivate static let measuringARow = #"""
        ## Measuring a row

        The height query and the cell's layout call one function, so measuring at
        one width and drawing at another is *unrepresentable* rather than merely
        discouraged.

        ```swift
        func height(ofRow row: Int) -> CGFloat {
            switch dataSource?.transcriptView(self, contentForRow: row) {
            case .markdown(let source):
                return MarkdownBlockBuilder.make(source).measure(contentWidth).size.height
            case .view:
                return delegate?.transcriptView(
                    self, heightOfRow: row, width: contentWidth) ?? 1
            case .userMessage, .image, .none:
                return 1
            }
        }
        ```

        Run the suite before believing any of it — and note that the chip reads
        `bash`, not the whole info string:

        ```bash filename="run.sh" highlight=1
        make test-kit FILTER=MarkdownRowTests
        ```

        An indented block is a code block too, and carries no language:

            swift build --package-path macos/TranscriptKit
            swift run TranscriptKitDemo
        """#

    /// Nested lists two deep, items holding several blocks, and an ordered list
    /// that does not start at one.
    fileprivate static let placingAnEntity = #"""
        ## Placing an entity into the layers

        1. **Data → Model.** A value type, `Codable` at the boundary, zero UI.

           Domain rules that are pure functions live here. What must *not*: an
           `NSColor`, an `NSImage`, or any answer to "how should this field look".

        2. **State and I/O → Service or Store.** A class with identity and a
           lifecycle, injected by initializer:

           - a *Service* is a capability provider — mostly verbs, `sync()`,
             `loadUser(id:)`
           - a *Store* exists to own a body of state and publish its changes
             - when one type does both, name it for the dominant role
             - when both halves grow large, that is the signal to split it

        3. **Rendering → View.** A dumb `NSView` that configures already-computed
           values and reports intent upward. It never learns a Service exists.

        Numbering need not start at one, and the renderer has to honour that:

        7. This item is the seventh.
        8. And this one the eighth.
        """#

    /// Every shape a list can take, in one place — the document to read when a
    /// list's rhythm or its marker column looks wrong.
    ///
    /// Between them: bullets, ordinals starting somewhere other than one, a task
    /// list in both states, three levels of nesting, an item holding two
    /// paragraphs, and an item holding a code block. Every vertical gap in here
    /// should be identical, at every depth, whatever the item contains — that is
    /// the one property this document exists to make visible.
    fileprivate static let listShapes = #"""
        ### Every list shape

        - A bullet item.
        - One with a sub-list under it:
          - Second level.
          - And a third:
            - Third level, to check the marker column re-negotiates per list.
        - Back out to the top level.

        Ordered, and not starting at one — the column widens for `10.` and the
        markers right-align on the period:

        8. Eighth.
        9. Ninth.
        10. Tenth, wider than the two above it.

        A task list, drawn rather than typeset:

        - [x] Checked — a filled box with Material's tick path on it.
        - [ ] Unchecked — the border alone.
        - [x] Both states share an advance width, so nothing shifts when one
              is ticked.

        Items are not limited to a line of text. This one holds two paragraphs:

        - First paragraph of the item.

          Second paragraph of the same item, which should sit exactly as far
          from the first as the items sit from each other.

        - And this one holds a code block:

          ```swift
          BlockStack(rows, spacing: 6).measure(width)
          ```

        - Back to something ordinary, to close the list.

        Every list above is **tight** — no blank line between its items, so they
        sit six apart. A **loose** one is the same list with the blank lines left
        in, and it breathes at the document's own twelve instead:

        * Loose, because a blank line follows.

        * Which CommonMark treats as a run of paragraphs that happen to be
          numbered, rather than one thought broken into lines.

        * cmark settles this while parsing and swift-markdown drops the answer,
          so it is recovered here from source line numbers.
        """#

    /// Footnotes, the three shapes an image takes, the autolinks GFM makes and
    /// the one it declines, and the punctuation that must reach the screen
    /// unchanged.
    fileprivate static let referencesAndNotes = #"""
        ### References, notes, and things that must not change

        Smart typography is off, and this is the line that proves it: run git
        commit --amend, he said "hi", and so on ... Two hyphens stay two hyphens
        rather than becoming an en dash, a straight quote stays straight, and
        three periods stay three. In a transcript those are program output.

        Bare domains stay text — socket.io, sentry.io and deno.land read as
        package names, and GFM agrees: its extended autolink wants a literal
        `www.` prefix or a scheme before it will link anything.

        Images take three shapes. Alt beats title, because alt is what an author
        writes *for* the case where the image is not shown — which is this one:

        - Alt only: ![throughput over the last hour](chart.png)
        - Title only: ![](chart.png "a title, standing in for absent alt text")
        - Neither, so the glyph carries it alone: ![](chart.png)

        Footnotes are numbered by first reference[^numbering], not by the order
        their definitions appear[^order]. A reference with no definition[^missing]
        stays as literal text, because dropping it would lose a word the author
        typed; a definition nothing refers to renders as nothing at all.

        [^order]: Defined first, numbered second — because `numbering` is
            referred to before it.

        [^numbering]: What GitHub does. A note holds blocks of its own:

                ListBuilder.make(items: notes, spacing: 6, gap: 7)

            including a second paragraph, indented four spaces under the first.

        [^unused]: Nothing refers to this one, so it never reaches the screen.
        """#

    /// A single paragraph — here so the script has a short row among tall ones,
    /// which is what makes recycling interesting.
    fileprivate static let shortAnswer = #"""
        Because the scroll view rewrites the document view's width back to the
        clip's on every `tile`, and not through `setFrameSize` — so the clamp
        cannot be held from inside the table.
        """#

    /// Every inline node in one paragraph, headings 4–6, and blockquotes nested
    /// two deep with blocks inside them.
    fileprivate static let inlineKitchenSink = #"""
        #### Every inline at once

        Plain text, *emphasis*, **strong**, ***both together***, ~~struck
        through~~, `inline code`, an [explicit link](https://swiftpackageindex.com),
        a [titled one](https://commonmark.org "Hover me — this is a link title"),
        a bare https://github.com/apple/swift-markdown, an extended autolink at
        www.commonmark.org, an address at core-team@swift.org, and an image
        standing in for itself: ![a diagram of the block tree](block-tree.png)

        A soft break folds into a space,
        like the one before "like", whereas a hard break\
        starts a new line without ending the paragraph.

        ##### Fifth-level heading

        ###### Sixth, for completeness

        > Quotes nest, and the inner one holds blocks of its own:
        >
        > > ```swift
        > > struct Blockquote: Block { let content: Block }
        > > ```
        > >
        > > - including a list
        > > - and a second item, to prove the bar spans both
        >
        > Back out one level. The bar is the whole of what `Blockquote` adds;
        > arrangement, hit testing and selection are the stack's.
        """#
}

extension DemoMessage {

    /// What the panel's **Stream** button reveals into a row, a few characters
    /// per frame.
    ///
    /// Appended to whatever the row already holds, so what you are watching is a
    /// document *growing* — which is the case worth watching, and the one
    /// `MarkdownMemo` exists for. Four things to look at while it runs:
    ///
    /// 1. **The blocks above the growing one do not move or flicker.** They are
    ///    not being re-typeset; they are the previous frame's, handed back by
    ///    value. If a change here ever breaks that, this is where it shows.
    /// 2. **Select some text in the row first, then start.** The selection
    ///    survives — the blocks before the divergence still occupy the same index
    ///    space. The same drag on a row you then *replace* would not, and should
    ///    not.
    /// 3. **Scroll up while it streams.** The viewport holds still. Scroll back
    ///    to the bottom and it follows the tail again, decided fresh each frame
    ///    from where the offset is.
    /// 4. **The list is the expensive shape.** A list is one block, so every
    ///    arriving character re-typesets all of its items — visible as nothing at
    ///    all here, and the ceiling worth knowing about.
    ///
    /// **No fence and no table in it, on purpose.** Both reflow violently while
    /// half-written — an unclosed ``` turns everything after it into code, and a
    /// table's columns resize on every row — so a host streams them by holding
    /// the incomplete structure back until it seals. That policy is the host's,
    /// this package has no opinion on it, and the demo has not implemented one:
    /// what it shows is the shapes that *are* safe to reveal as they grow.
    static let streamed = #"""


        Streaming is `reloadRows(at:)` on a timer. The host changes its model and
        announces the row; the transcript works out for itself that the source
        moved, and re-typesets only the blocks that are not the ones it laid out
        a frame ago.

        ### What it costs

        Three things happen per frame, in ascending order of expense:

        - the source is **parsed** whole, because cmark has no incremental entry
          point and appending three characters can change what the lines above
          them mean;
        - the blocks that changed are **shaped and typeset**, and the ones that
          did not are looked up by value;
        - the row is **repainted** whole, which is the next thing to fix and the
          reason a very long streamed message is still not free.

        None of that is API. The host hands over a string and says which row; the
        arithmetic of what changed belongs to the side that can see both versions.
        """#
}
