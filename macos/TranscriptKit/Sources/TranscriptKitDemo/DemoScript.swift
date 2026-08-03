import Foundation

/// One turn in the demo transcript.
struct DemoMessage {
    enum Author { case user, assistant }

    let author: Author
    let text: String
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
    /// Between them the seven documents use every node `MarkdownIR` has: all
    /// six heading levels, ordered / unordered / task / nested lists with a
    /// start index, fenced code with and without a language plus an indented
    /// block, a table carrying all four alignments, nested blockquotes holding
    /// blocks of their own, thematic breaks, and — in `inlineKitchenSink` — one
    /// paragraph containing every inline node at once. A shape that renders
    /// wrongly is visible on this screen; a shape missing from here is a shape
    /// nobody is looking at.
    static var script: [DemoMessage] {
        [
            .user("What shipped in 0.3?"),
            .assistant(releaseNotes),
            .user("Remind me what actually happens in one runloop iteration."),
            .assistant(runloopTick),
            .user("How do I pick between a delegate and a Combine publisher?"),
            .assistant(mechanismTable),
            .assistant(measuringARow),
            .user("And how should I lay a new domain entity out?"),
            .assistant(placingAnEntity),
            .assistant(shortAnswer),
            .user("Show me every list shape at once."),
            .assistant(listShapes),
            .assistant(inlineKitchenSink),
        ]
    }

    static func user(_ text: String) -> DemoMessage {
        DemoMessage(author: .user, text: text)
    }

    static func assistant(_ text: String) -> DemoMessage {
        DemoMessage(author: .assistant, text: text)
    }
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

        A table is the one shape whose selection is genuinely two-dimensional:
        dragging from *Cardinality* down two rows should take a rectangle, not a
        text range that swallows everything in between.
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

        Run the suite before believing any of it:

        ```bash
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
        a bare https://github.com/apple/swift-markdown, and an image with no
        renderer behind it yet: ![a diagram of the block tree](block-tree.png)

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
