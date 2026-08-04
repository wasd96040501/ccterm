# TranscriptKit

Standalone Swift package: one AppKit view, `TranscriptView` — a chat
transcript driven by a data source.

## 1. Mirror `NSTableView`

The public surface is `NSTableView`'s, name for name and signature for
signature: `numberOfRows`, `reloadData()`, `insertRows(at:withAnimation:)`,
`removeRows(at:withAnimation:)`, `noteHeightOfRows(withIndexesChanged:)`,
`beginUpdates()` / `endUpdates()`,
`scrollRowToVisible(_:)`, `rect(ofRow:)`, `row(for:)`. The data source /
delegate split is AppKit's too — the data source says *what* the rows are,
the delegate says *how they appear*.

This is about the host's cost of entry. Anyone who has written an
`NSTableViewDataSource` already knows this API, and can check an intuition
against Apple's documentation instead of ours.

Before adding or renaming anything public, look up the AppKit counterpart —
`make appkit-doc SYMBOL=NSTableView` — and take its spelling unless §2 applies.

## 2. Deviate where AppKit is wrong, and write down why

Parity is the default, not something to follow off a cliff. Where AppKit's
shape is a historical accident or a known footgun, take the better shape and
put the reason in the doc comment. Standing examples:

- **`makeView(withIdentifier:make:)`** returns a generic `V` built by a
  factory closure, rather than AppKit's `owner: Any?` → `NSView?`. AppKit's
  signature serves nib loading; in a code-only package it forces every call
  site through `as? Foo ?? Foo()` plus a manual `identifier` assignment — and
  forgetting that assignment silently disables recycling.
- **`heightOfRow(_:width:)`** carries a `width` AppKit's has no use for.
  There, column widths were the host's to set, so the host already knows them;
  here the transcript derives the width itself and has to hand it over.
- **No `frameOfCell(atColumn:row:)`, no `didAdd`.** The first is a column
  accessor in a view that has no columns. The second is a hook AppKit needs
  because it builds row views itself, whereas `viewForRow` already *is* that
  moment.
- **No `withAnimation:` on the mutations.** AppKit's options animate *row
  geometry*, which is the one thing scroll anchoring exists to hold still: rows
  sliding into place over a quarter second while the compensating scroll offset
  is already final is a visible shake, and no amount of care reconciles the two
  — NSTableView's row animation exposes no progress or completion to drive the
  offset from. It shipped, was watched shaking in the demo, and came back out.
  A host that wants an arrival to be visible animates inside its own view, where
  nothing moves the rows.

A deviation with no reason in the comment is a bug: restore parity, or write
down why not.

## 3. Nothing speculative

Public API lands when a caller needs it, not when it looks likely to be
needed. A `contentWidth` property nearly shipped here on the theory that a
host *might* want to mirror the transcript's metrics elsewhere; nothing did,
so it didn't. The rest of `NSTableView`'s surface — `rows(in:)`,
`moveRow(at:to:)`, the selection family — stands on the same footing: add it
the day something calls it.

## 4. Don't re-grow NativeTranscript2

The renderer this replaces reached ~18 000 lines because it drew everything
itself: each new kind of content meant a new `Block.Kind`, a new `XxxLayout`
file, a case in the `RowLayout` enum, and an arm in three separate switches.
Extending it meant editing it. Three rules keep that from happening again:

- **The content vocabulary is closed.** `TranscriptRowContent` has four cases
  and gains none. Anything richer — tool cards, groups, attachment strips,
  progress rows — is `.view`, drawn by a host `NSView` this package never
  has to know about. A feature that seems to need a fifth case needs a
  `.view` instead.
- **Collaboration goes through the two protocols.** No `onSomethingChanged`
  closures threaded between internal types, no `@Observable` request fields
  the host is expected to watch. A new host-facing event is a delegate
  requirement with a default implementation — that is the whole mechanism.

  The **context menu** is where this gets leaned on hardest, so it is worth
  saying what shape it took. `transcriptView(_:menu:forRow:)` hands over the
  menu the transcript would show and takes back the one that gets shown. The
  transcript contributes only commands it can implement itself — today, Copy,
  which depends on a selection no host can see — and *executes* only those.
  Quote, Retry, Copy as Markdown and everything else of that kind depend on a
  model this package will never know about, so they are items the host appends
  carrying its own target and action; nothing routes back through here when one
  is chosen. That asymmetry is the point: a proposal that comes back edited is
  the only shape where each side writes the half it can, and it is why the next
  five menu items cost no new API.

  The demo does **not** implement the hook, on purpose. What it shows is what a
  host that has not thought about menus yet gets — Copy alone — and the hook's
  own behaviour is assertable rather than eyeball-only, so `ContextMenuTests`
  carries it instead (§5).

  Two consequences fall out rather than being decided. The menu is built fresh
  per click — a shared instance in `NSView.defaultMenu`'s class-property shape
  would accumulate another copy of the host's items on every right-click. And
  `.view` rows never reach the hook: a host-drawn row already has a view of the
  host's own, and AppKit finds a menu by asking the view under the pointer, so
  the hook exists precisely where that option does not.
- **Ordering contracts live in the API shape, not in prose.** `dataSource`
  deliberately does not refresh on assignment; the host has to call
  `reloadData()`, so "wire it up, then load" cannot be got wrong by accident.
  When a sequence has to run in a particular order to be correct, make the
  wrong order unrepresentable or harmless. Don't write the order down and add
  a test to guard the writing.

## 5. Tests: mount it, and prove the mount works

`make test-kit` (or `swift test` in this directory). Its own suite rather
than a slice of the app's `cctermTests`, so the package stays testable
without the app — which is most of the reason it is a package.

Almost nothing here is testable as pure logic. `NSTableView` only asks its
data source and delegate anything when it lays out, so a test mounts a real
`TranscriptView` in an off-screen window (`MountedTranscript`) and asserts
on geometry and on **what the transcript asked for**: the widths passed to
`heightOfRow`, how many times, how many views were built rather than
recycled. That second kind catches more than the first — a wrong width or a
doubled measurement pass is invisible on screen.

Three rules, learned the hard way:

- **The harness has no logic.** Build a window, mount, flush layout, drain
  the runloop. No branches, no derived expectations, no helper that computes
  what a test should assert. A harness with nothing to get wrong needs no
  verification of its own.
- **Every test opens by asserting the transcript was provoked.** A mount
  that silently never lays out makes every later assertion pass on an empty
  tree. `heightWidths.isEmpty` failing is the difference between a green
  suite and a meaningful one.
- **Verify a new test by breaking the code it covers.** Short out the
  production path, run, and check that *that* test goes red while the others
  stay green. This is the only step that can falsify the harness; skipping it
  means shipping tests whose green is unexplained.

`settle()` runs **one** pass on purpose. The transcript's width invalidation
lands inside the pass that changed the width, so nothing is left for a second
round to settle — a change that starts needing `passes: 2` has pushed work
onto a later tick, which is a visible frame at the old geometry, not a test
detail.

### What the suite can't check: `make demo-kit`

Run from the repo root, like everything else here — `make test-kit` and
`make demo-kit` are the package's two entry points, and both just wrap
`swift test` / `swift run TranscriptKitDemo` in this directory. The demo runs
in the foreground; close the window to stop it.

A test can assert a row's height, the width it was measured at, and how many
views got built instead of recycled. It cannot assert that the document in
that row **looks like a document** — that the gap under a heading differs from
the gap under a paragraph, that a quote's bar starts and ends with its glyphs,
that a code card has room to breathe. Those get read, not asserted, and
markdown rendering is mostly made of them.

So `DemoMessage.script` is eight real markdown documents rather than generated
filler, and between them they use every node in `MarkdownIR`: all six heading
levels, ordered / unordered / task / nested lists with a start index, tight
lists beside loose ones, fenced code with and without a language plus a
multi-word info string and an indented block, a table carrying all four
alignments and a spanned cell, nested blockquotes holding blocks of their own,
thematic breaks, footnotes in all four of their states (referenced, referred to
twice, referenced-but-undefined, defined-but-unreferenced), images with alt /
with title / with neither, and one paragraph containing every inline node at
once. **A shape missing from that script is a shape nobody is looking at** —
landing a new one means adding it there too.

Some of what only the eye catches is *absence*: that `--amend` did not become
`--amend`, that `socket.io` did not turn blue. `referencesAndNotes` exists to
put those side by side, because a regression there reads as ordinary text and no
assertion elsewhere is looking at it.

**A hover is drawn here and said out there.** The band under the run is the
transcript's, because only this side knows which rectangles a run occupies — a
host has no way to ask. The *label* is the host's: what it says, whether it
follows the pointer, whether it appears at all, reached through
`transcriptView(_:didHover:at:inRow:)` with the demo's `LinkTooltip` as one
answer. That is §4 drawn along the line where the knowledge actually is, rather
than along the one that first looked obvious — an earlier note here said "a
hover is reported, not drawn", which was right about the label and wrong about
the run.

The band is a `CAShapeLayer`, not a `PaintItem`, and it is the only thing in the
renderer that changes on its own clock. A paint list is a snapshot played
synchronously, with no notion of time in it, so fading one in would mean
repainting the row every frame for a fifth of a second; as a layer it is
interpolated by the render server and this side draws nothing at all. That is
also why a row's painting lives on `SurfaceLayer`s rather than in the view's own
layer: CoreAnimation composites `contents` *below* `sublayers`, so a layer can
only get under the glyphs if the glyphs are themselves on a surface above it.

Two consequences worth keeping in mind when touching either:

- **A `CGColor` on a layer does not follow the appearance.** The `NSColor`s in a
  paint list are resolved against whatever is current at draw time and a repaint
  is the whole fix; the band's fill is resolved once and has to be re-resolved by
  hand in `viewDidChangeEffectiveAppearance`. Same for `contentsScale`, which
  AppKit maintains on its own layer and not on ones put there by hand.
- **`cacheDisplay` does rasterise these layers.** Measured, both directly and
  nested inside a scroll view rasterised from the outside — so a snapshot of a
  row does include its surfaces and its band. Worth knowing precisely because the
  opposite would have been a quiet class of blank-looking snapshots.

The split also lands the testable half on the near side. A real hover cannot be
provoked from a test — `xctest` never becomes the active application, so a
tracking area scoped to the key window never arms, and no synthetic event
substitutes for a pointer resting somewhere; measured, not assumed, after an
afternoon of trying, and the same reason AppKit's own `addToolTip` is
unreachable from here. But `mouseMoved` is an ordinary method, so both halves are
assertable without one: the *report* fires, says `nil` on the way out, and is one
call per link rather than one per pixel; and the *band* is a sublayer, so that it
exists, that it is the bottom-most layer, what its path covers, and that a
rebind takes it away are all readable from outside without a hook added for the
purpose. What still needs eyes is the part no assertion has an opinion on — the
alpha, whether a wrapped run reads as one band, and the demo's label.

The `.view` bubbles interleaved with them are down to a handful on purpose:
enough to keep both row kinds sharing one recycling pool, which is where a cell
handed back from the wrong kind of row would show up, and not so many that they
crowd out the thing being looked at. The control panel stays regardless — the
mutation buttons are how scroll anchoring gets checked, and no rendering change
should cost that.

## 6. How a host is expected to load

Not a rule about this package's code — a note on how hosts drive it, recorded
here so nobody reaches for machinery that isn't needed.

**Mount, lay out, then load.** Add the transcript, activate its constraints,
`layoutSubtreeIfNeeded()`, and only then `reloadData()`. Loading first measures
every row at a width of zero and again at the real one, and the correcting pass
is a full-table `noteHeightOfRows` — which AppKit animates, so the first screen
arrives and then visibly settles. `NSTableView` has exactly this behaviour
whenever the host's row height depends on width; the app's `NativeTranscript2`
answers it the same way, by building its scroll view unbound and binding the
data source after the layout pass (`TranscriptScrollViewFactory`).

This stays the host's job. The transcript could defer its own binding until it
has a width, and that was tried: it costs a state the host cannot see, mutations
that silently do nothing while in it, and a `numberOfRows` answered from two
different places. Parity with `NSTableView` (§1) is worth more than protection
from an ordering a host gets right once, in the ten lines where it mounts.

A long transcript loads by rendering the first screen, then feeding the
remainder in batches, **one batch per `DispatchQueue.main.async` hop**. Each
tick typesets a batch small enough to fit the frame budget, so the cost is
spread across ticks instead of landing in one.

Two properties make that work:

- **Mutations settle on the next layout pass, not inside the call.** Batches
  separated by an `async` hop therefore settle in separate passes. Ten
  `insertRows` calls in the *same* tick coalesce into one pass and cost what a
  single call of that size would — the hop is what spreads the work, not the
  number of calls.
- **Scroll anchoring makes it invisible.** Batches prepend above the viewport
  over several hundred milliseconds while the reader is already reading, and
  the anchoring rules documented on `TranscriptView` hold the content still
  throughout. The two designs are a pair; neither is much use alone.

This is why the package has no paging protocol, no visible-range observation,
and no off-main typesetting. That apparatus exists to serve a sliding window
over an unbounded history — Telegram's `ChatHistoryLocation` is the reference
design, and it earns its complexity on chats with hundreds of thousands of
messages. A transcript is a bounded document that ends up fully resident, so
the same apparatus buys nothing here. Should a genuinely unbounded source turn
up, adding visible-range observation back is pure addition — don't add it
before then (§3).
