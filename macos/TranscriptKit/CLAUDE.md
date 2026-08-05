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

- **The content vocabulary is closed.** `TranscriptRowContent` has three cases
  and gains none. Anything richer — tool cards, groups, attachment strips,
  progress rows — is `.view`, drawn by a host `NSView` this package never
  has to know about. A feature that seems to need a fourth case needs a
  `.view` instead.

  It went the other way once, which is the more useful direction to record. A
  fourth case, `image(NSImage)`, shipped here and never grew a block behind it —
  it measured to nothing and drew nothing for as long as it existed. Deciding
  what it *would* have taken settled the rule: decode, a placeholder while that
  runs, a failure state, an original that is not the copy on screen, and a press
  that opens something. Five host concerns, against one line of arithmetic —
  fitting a bitmap to the content width — that is the same line on either side of
  the seam. So it came out, and pictures are a `.view` row like everything else;
  `TranscriptMedia`'s `ImageGridView` is one host's answer rather than this
  package's. A case that has been in the enum for months and still has no
  renderer is not pending work, it is a decision that was made and not written
  down.
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

The **press** tint is the same shape of claim. That it deepens on mouse-down,
returns on mouse-up, and gives up the moment the press becomes a drag are all
assertable and asserted; that the step from 8% to 16% reads as *the same band
pressed* rather than as the row flinching is not, and is the reason the number is
Telegram's rather than ours. Its geometry is Telegram's too — each rectangle
inflated by 2 before it is rounded at 4 — which is what keeps the tint from
looking clipped by the first and last stem of the run. Both are one constant each
in `BlockView` if they ever want to be louder.

A user turn is a `.userMessage` row, drawn by the package like the documents
around it, so **no text row in the demo is a host row** — the `.view` bubbles
that used to be interleaved here are gone, and what the text half shows is a host
that never has to implement one. What they guarded — that both row kinds share
one recycling pool, where a cell handed back from the wrong kind of row would
show up — is asserted in `UserMessageRowTests` instead, which is the better home
for it: the symptom is a row rendering another row's content, and a test can see
that as readily as an eye can. The control panel stays regardless — the mutation
buttons are how scroll anchoring gets checked, and no rendering change should
cost that.

The demo's **picture** rows are `.view`, and are the one place it implements
`heightOfRow` and `viewForRow`. They are not there to prove the hook works —
tests do that — but because the mosaic underneath them cannot be checked any
other way: which branch of `MosaicLayout` a group takes is decided by the
pictures' proportions rather than by how many there are, so two pictures may go
through the hand-written pair rule or through the line-split search depending
only on shape. `DemoImage` draws its own pictures at fixed ratios and labels each
with its index and proportion, and the script walks the branches in the order the
algorithm reaches them. A tile in the wrong row, or a group that stopped filling
its column, reads instantly on that screen and is invisible in a number.

What the bubble needs eyes on is what no assertion has an opinion about: that a
three-word message reads as a small pill rather than a band with space in it,
that the gutter the cap leaves is enough to make the row read as one side of a
conversation, and that the fill against the accent is a tint rather than a block
of colour. The geometry under all three — hug, cap, right edge, padding — is
`UserMessageTests`.

The same split runs through **More**, the run under a message the transcript had
to cut short. That it is a link in the only sense this package has — `link(at:)`
answers for it, so the band, the pointing hand and the press-is-a-click rule are
`BlockView`'s existing ones — is asserted on both sides of the seam
(`UserMessageTests`, `UserMessageRowTests`). What is not, and is the reason the
demo's script carries one message long enough to trigger it: whether the ellipsis
and the run under it read as *one* thing the reader can act on, and whether a
band at the link tint is still legible over an accent-tinted bubble rather than
over the window.

Pressing it now reports `transcriptView(_:didActivateMoreInRow:)`, the
requirement that was reserved for the first host with somewhere to put the rest.
What it carries is **the row, and nothing else**. Not the message: the host put it
in the data source, so reading it back would be the package answering a question
about a model it is only borrowing, and would tempt a host into previewing the
copy the transcript cut rather than the one it owns.

It carried a rectangle too for a while — the bubble's, so a presentation could
grow out of what was pressed, which is the one part a host cannot work out for
itself (`rect(ofRow:)` answers the *row*, and a bubble is three quarters of a
content width against its trailing edge). Getting it out cost a downcast at the
call site, and before that a `MeasuredBlock.inkFrame`: a protocol requirement with
one implementer and one caller, a default implementation, and a paragraph
explaining that it had to be a requirement rather than an extension member because
existentials dispatch extension members statically. Three shapes for one
rectangle, and **nothing was flying out of it** — no host had built the
presentation the parameter existed to serve. It comes back the day one animates,
with that animation's shape known rather than guessed at.

Worth keeping from the round trip: a mechanism that needs a paragraph about
dispatch to be correct is usually the wrong shape, and generality with a single
implementer is §3's speculation wearing a protocol as a disguise. What crosses
this seam is also *only* this — the band, the pointing hand and the
press-is-a-click rule are all `BlockView`'s, computed from the link's own range,
and none of them are affected by what the delegate is handed.

What it must not become is an in-place expansion. That was the obvious cheap
answer — the block already holds the whole string and already does the cutting,
so ignoring the cap for one row and re-measuring is a few lines — and it is a bad
one: a five-hundred-line paste unfolds under the reader, and collapsing it again
means scrolling back to find the affordance. One press, one navigation. The rest
of a long message belongs on a surface of its own, which is `TranscriptMedia`'s
`MessagePreviewView`.

**Streaming is on the panel because none of it is assertable.** A test can prove
that the blocks above a growing one were not typeset again (`MarkdownGrowthTests`
reads `CTLine` identity for exactly that) and that a selection survived. It
cannot see whether the settled text *twitched*, whether the growing paragraph
reflows in a way that is pleasant to read at 120 characters a second, or whether
scrolling through a row that is growing under the pointer feels stable. Type a
row number, press **Stream**, and then: select some text in that row first and
watch it survive; scroll up and watch the viewport hold; scroll back down and
watch the tail re-engage.

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

### Streaming is `reloadRows`, and the increment is derived here

A row whose markdown arrives a token at a time is `reloadRows(at:)` on a frame
ticker, and there is **no delta API** — the host hands over the whole source
every time, the same way it does for any other content change.

Not an omission, and worth the four reasons because it is the first thing anyone
proposes:

- **The data source is a pull model.** `contentForRow` is re-asked on recycling,
  on a width change, on `reloadData` — so the host holds the whole string
  regardless. A second, incremental channel would be the same content arriving
  two ways, and the two disagreeing is a silent wrong render rather than a crash.
- **Markdown does not compose by appending.** Three arriving characters can turn
  the six lines above them into a code block; a delimiter row turns the line
  above it into a table header; a footnote definition renumbers markers earlier
  in the document. A renderer handed a suffix would have to re-read backwards to
  an unknowable point, so the delta buys it nothing.
- **A stream does not only grow.** The authoritative text replaces the streamed
  text at the end, a retry rewrites it, a held-back fence is released whole. Each
  is a verb an incremental protocol would have to grow; against a whole source
  they are all just "this row's content now".
- **Passing the string is free.** Swift strings are COW; handing over 8 KB is a
  retain.

So the increment is worked out on this side, by the party that can see both
versions. `MarkdownMemo` keys every top-level child of the document on the IR
value it was built from — which is why every `MarkdownIR` value is `Hashable` —
and hands back the ones that did not change. Because `BlockStack` assigns origins
and index bases at stacking time, a reused child needs nothing done to it
wherever it now lands, so this is a **memo, not a diff**: no edit script, no
block identity, no stable-id scheme of the kind `NativeTranscript2` needed for
blocks that were themselves rows.

Three costs, and only the middle one is solved:

| | per frame | status |
|---|---|---|
| Parse | cmark over the whole source | paid in full — no member of that family has an incremental entry point, and it is the cheapest of the three by an order of magnitude |
| Shape + typeset | only the blocks that changed | what `MarkdownMemo` is for |
| Repaint | the row's surfaces, whole | **untouched** — `BlockView.invalidate()` takes no rect |

The repaint is the one left standing, and the reason it was not done with the
others is that it is not merely plumbing: a streaming row's layer is **growing**,
and a partial `setNeedsDisplay(_:)` on a layer whose bounds just changed leaves
the region outside the dirty rect showing the old bitmap under
`contentsGravity`'s default resize. Whether that reads as stale stretched pixels
or as nothing at all has to be watched on a screen, which is `make demo-kit`'s
department and not the suite's. Start there before writing the plumbing.

What stays the host's is *what* to hand over. An unclosed fence turns the rest of
the message into code and a half-built table resizes its columns on every row, so
holding an incomplete structure back until it seals is a product policy — some
hosts want code revealed as it streams. The app answers it in
`StreamingMarkdownCommit`, one pure function, host-side, and the demo answers it
by streaming only shapes that are safe to reveal.

This is why the package has no paging protocol, no visible-range observation,
and no off-main typesetting. That apparatus exists to serve a sliding window
over an unbounded history — Telegram's `ChatHistoryLocation` is the reference
design, and it earns its complexity on chats with hundreds of thousands of
messages. A transcript is a bounded document that ends up fully resident, so
the same apparatus buys nothing here. Should a genuinely unbounded source turn
up, adding visible-range observation back is pure addition — don't add it
before then (§3).

## 7. The other side of the seam: `TranscriptMedia`

A second target in this package, and a second product: the parts §4 keeps out of
the renderer, written once so the demo and the app get the same ones. The
dependency arrow is `TranscriptMedia → TranscriptKit` and the compiler holds it
— nothing in the renderer can name a window, an overlay or a grid.

Two targets rather than one folder because a boundary both sides can `import`
across is not a boundary. §4 is a rule about what this package refuses to own,
and the honest way to state a rule like that is a build edge rather than a
paragraph.

**Named for a domain, not for a role** — the part to defend when the next thing
wants to live here. It was `TranscriptMedia` only on the second try; the first was
`TranscriptChrome`, lifted from §5's own phrase about the renderer "growing chrome
it has no business owning". Bad three times over: AppKit contains the word nowhere
(zero hits across its headers, and no framework is named for it), "chrome" means
the framing *around* content where the largest file here arranges the content
itself, and this codebase had already spent the word on the host bars a transcript
scrolls under — `contentInsets`, `ControlPanelView`, `LinkTooltip`. Worst of all
its boundary was "host-side things", which is wide enough to admit anything: the
grab-bag the project rules forbid, arriving under a spelling they don't list.

`TranscriptMedia` has an edge. Pictures, how a group of them packs, and the viewer
they open into is the whole of it, and a host component that is *not* media cannot
drift in unnoticed. When one turns up the answer is a third target or a rename —
either is a decision taken on purpose, which is what a name you can violate is for.

What lives there today, and the claim each one makes:

- **`MosaicLayout`** — Telegram's `GroupedLayout.measure`, ported rather than
  invented, down to its constants (spacing 4, minimum 70, ratios clamped to
  0.667…1.7, a target of four-thirds the offered height) and its two quirks,
  both marked in the source: the average ratio is seeded at 1.0 before summing,
  and a group leaning tall is allowed four in its middle row instead of three.
  Ported because the interesting cases are the ones intuition gets wrong — two
  panoramas, a portrait beside two squares, five pictures of unrelated shapes —
  and Telegram's answers have been looked at by a great many people. It is
  **not** a grid: nothing is cropped square, every picture keeps its proportion,
  and the algorithm chooses where the row breaks go.
- **`ImageGridView`** — the `.view` row those rectangles are drawn into. Outer
  corners 17, inner corners 5, both Telegram's; not zero on the inside, because
  two square corners across a four-point gap read as a crack rather than a seam.
- **`MediaOverlayWindow`** — Telegram's `GalleryViewer` mechanism: a separate
  borderless transparent window the size of the screen, with the 90% black
  dimming drawn *inside* it as an ordinary layer-backed view. The split is
  load-bearing — a window-level background colour is all-or-nothing and cannot
  animate apart from the content, and the whole effect is the surround darkening
  while the content flies out of the row it was sitting in.

  The flight is `animate(oldRect:newRect:)` in full, and every constant in it was
  looked up rather than recalled, because the first three attempts at it were all
  plausible guesses and all wrong. Three worth keeping in mind before touching it:

  - **`.spring` is a `CASpringAnimation`**, not a bezier — mass 3, stiffness 1000,
    damping 500, played linearly. Damping 500 against a critical damping of
    `2 * sqrt(3 * 1000) ~= 110` is heavily overdamped: no bounce, a very soft
    settle. `easeOut` is not a substitute and the difference is the whole of
    whether it reads as smooth. The 0.5s spring is re-timed to 0.25 by `speed`,
    not by shortening it, because a spring re-timed by duration is a different
    curve.
  - **A layer-backed `NSView`'s layer has `anchorPoint` (0, 0)** — measured, a view
    at (137, 421) reports `position` (137, 421), not its centre. So `position` is
    the frame's origin and a scale pivots on that same corner, which is why
    animating origins alongside a scale maps one rectangle onto the other exactly.
    Rewriting it around centres, as looked obviously right, put the model value
    half a view away from the animation's `toValue` and the layer snapped on the
    last frame.
  - **Two views fly, not one.** The scales are independent per axis, so the content
    is squashed to the source's proportions at the collapsed end; a still of the
    source — crop, rounded corners and all — crossfades against it and is opaque
    exactly where the squash would show. `ImageGridView.snapshot(ofTile:)` is
    where that still comes from, and it exists because the source is a tile inside
    a row rather than a view that could be copied.

  One deliberate deviation, with its reason: Telegram re-takes key on
  `windowDidResignKey`, which makes their gallery modal against the entire
  system. Here the overlay is a **child window** of the host, so it orders,
  minimises and hides with the window whose transcript opened it and needs no
  focus grab to stay in the right place. Theirs is right for an app-global
  viewer; this is right for a panel over a document.
- **`ImagePreviewView`** / **`MessagePreviewView`** — the two things that open
  into it, both answering one requirement: given the space, what rectangle do
  you want.

`MessagePreviewView` deliberately does **not** mount a second `TranscriptView`
with one uncollapsed row, which would have been fewer lines and would have
inherited the typography exactly. A row is painted onto `SurfaceLayer`s sized to
the row and split by paint phase, not by height; with the line cap removed, a
pasted file's row is as tall as the file and its backing store goes with it.
`NSTextView` lays out by visible range, so length stops being a question, and
selection, find and copy arrive rather than being re-earned. The two renderers
agree without sharing code because `UserMessage` is plain text on purpose.

Its face is larger than the transcript's and is **not** derived from it. A row in
a list is read in passing at a size chosen against its neighbours; a column alone
on a darkened screen is read at length. Two problems, two constants — a delta
would tie them together and neither would be right.

The same reasoning that put the image case out of the vocabulary is the reasoning
that fills this target. When something new arrives that seems to need a renderer
change, the first question is whether it is a picture-shaped problem: presentation
with product decisions in it, and a model the renderer would have to borrow. If
so it belongs here, and costs the renderer nothing.
