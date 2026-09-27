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
`TranscriptView` in a real window (`MountedTranscript`, over `TestWindow`) and asserts
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
- **A test that compares two configurations must assert that the two differ.**
  The same failure as the rule above it, one level up: `PreparedRowsTests`
  checks that a batch measured at 600 points does not get used at 420 by
  comparing against a control transcript — and three of its four documents were
  short enough to wrap identically at both widths, so it stayed green through a
  break that filed every stale measurement as current. The fix is a line
  asserting the premise (*these widths really do produce different layouts*),
  and it belongs next to any assertion whose meaning depends on two inputs not
  being equivalent.

### One harness: a window the window server composites

Every test mounts through `TestWindow.make`, and there is no other way in. The
window is **really on screen**: parked hanging off the bottom-left corner of the
main display with a single point showing, opaque — so the window server composites
all of it, and what a test reads is what a reader would see. It is never made key
and the process runs with the `.prohibited` activation policy, so the person at the
machine keeps the focus and the frontmost application never changes — measured,
not hoped for. A suite run can go on while you work.

It replaced two harnesses, and the reasons are the rules:

- **Not thirty thousand points off.** The old mount lived there, and "off-screen"
  was a different machine from the one a reader has. AppKit deferred the first
  measure until layout there, so `reloadData()` before the first layout passed;
  composited, the table asks at once, exactly as the demo's does, and the geometry
  tests failed until they mounted, laid out, *then* loaded (§6). A harness whose
  window is not composited tests an ordering no host can rely on.
- **Not `cacheDisplay`.** It redraws a view in-process and sets up AppKit's drawing
  state on the way — which is how it drew correctly through a bug that left rows in
  the wrong appearance on screen. A pixel assertion reads
  `WindowCapture.bitmap(of:)`: the composited window, cropped to the view, one pixel
  per point. `testTheDimmingStaysInsideTheTranscript` is the kind of thing only this
  sees — a clip is applied by the window server, and no frame shows one missing.

**The mount's size is the test's, on every machine.** `NSWindow`'s initialiser
puts a new window on a screen — and on one too small for it, shrinks it — so the
harness sets the frame again after init, and `constrainFrameRect(_:to:)` returns it
unchanged so `orderFront` cannot pull it back. Without that, the first CI run — a
1024×768 runner — gave the scroll tests a viewport 78 points short. Assigning a
`contentViewController` sizes the window to the controller's view, so a test that
does that parks the window again afterwards (`TestWindow.park`). Anything else a
test reads from the machine is the same kind of input: SF Symbol metrics snap to the
main screen's pixel grid, so `InlineSymbolTests` checks its recorded numbers only on
the 2x screen they were recorded on.

`settle()` runs **one** pass on purpose. The transcript's width invalidation
lands inside the pass that changed the width, so nothing is left for a second
round to settle — a change that starts needing `passes: 2` has pushed work
onto a later tick, which is a visible frame at the old geometry, not a test
detail.

### Capturing: `WindowCapture`

Through ScreenCaptureKit: `SCShareableContent.currentProcess` (macOS 14.4) lists
this process's own windows without asking for Screen Recording, and
`SCContentFilter(desktopIndependentWindow:)` captures one whole. Two things about it
were learned by it failing, both reproduced outside XCTest:

- **A capture fails transiently** — `-3811`, or an invalid transition — on a window
  just ordered in, or fired straight after another capture, though the window is
  already listed on screen. So a capture orders the window front, waits two frames
  of its display's link for the commit to be composited, and retries a failed
  attempt up to thirty times, two frames apart.
- **A frame wait has a deadline.** A display that presents no frames — a locked
  screen, a sleeping one — would otherwise hang the suite; it was ten minutes the
  first time. After five seconds the wait throws `XCTSkip` instead, which says what
  happened rather than failing a test that could not run.

What a test still cannot do on this harness, all measured, so nobody re-derives
them:

- **Start a real drag.** `beginDraggingSession` from a test process begins, never
  ends, and stays attached to the real pointer until the person at the machine next
  lets go of a button — dropping into whatever is under it. So `EditorTabBar` splits
  a tab leaving the bar into `dragWillBegin(tabAt:)` / `dragDidEnd()`, which the
  real session calls and a test calls directly, and destinations are handed a
  `StubDraggingInfo` through the same `NSDraggingDestination` methods AppKit calls.
  A drag *along* the bar starts no session — it is mouse events, which a test sends
  to `mouseDown` / `mouseDragged` / `mouseUp` like any others.
- **Press a left button through `NSApp.sendEvent`.** It can make the window key.
  `EditorAreaTests` exercises the area's event monitor with an other-mouse-down,
  which the monitor watches and which activates nothing.
- **Click a segment of an `NSSegmentedControl` laid out by constraints.** The same
  synthesized press lands when the frame is set by hand, and always on a cell-based
  control; on this one the action is never sent. And a momentary control's
  `selectedSegment` does not keep a value written from outside. `FindBarViewTests`
  presses the segments the way VoiceOver does, through their accessibility elements.

Captures are `*SnapshotTests`, written to `/tmp/transcriptkit-screenshots/`, and
skipped by `make test-kit` unless named — `make test-kit FILTER=<Class>`. They
assert premises, not pixels: they are for reading, like the demo, but without a
window taking over the screen. `FindPresentationSnapshotTests` and
`EditorAreaSnapshotTests` are the two. A pixel *assertion* is not a snapshot — it
runs in the default suite like any other test, and reads `WindowCapture.bitmap`.

### What the suite can't check: `make demo-kit`

Run from the repo root, like everything else here — `make test-kit` and
`make demo-kit` are the package's two entry points, and both just wrap
`swift test` / `swift run TranscriptKitDemo` in this directory. The demo runs
in the foreground; close the window to stop it.

The window is an editor area (§9): each tab is one transcript with its own host,
its own find bar and its own stream, and a second editor opens on the right
(⌃⌘T). The tools float in glass at the bottom centre: a round toggle, and beside
it a capsule showing one section at a time (Editors, Scroll, Mutate, Stream, Cold
Load, Content Width). The toggle, or ⌥⌘T, folds the capsule into it. Every tool
acts on the **active** editor's selected tab.

The palette is built the way AppKit builds a toolbar, and is worth copying rather
than re-deriving: its buttons are **nil-targeted actions, the same selectors as
the menu items**, so a tool and its menu item are one command with one
implementation; they are enabled by the window controller's one
`validateUserInterfaceItem(_:)`, asked on every window update the way a toolbar
asks for its items; and a command that carries a value is sent with the palette as
its sender and reads the value off it, as `changeColor(_:)` reads an
`NSColorPanel`. Folding is a stack view hiding an arranged view inside an
animation group, with both pieces of glass in one `NSGlassEffectContainerView`.

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
- **"Whatever is current" is the process's, inside a surface.** `draw(_:)` gets
  the view's effective appearance made current by AppKit; a sublayer's
  `draw(in:)` is CoreAnimation's call and gets nothing, so `SurfaceLayer` makes
  it current itself. Without that a window or view given an appearance of its own
  drew its rows in the system's — black prose on a dark window — and nothing
  in-process showed it, because `cacheDisplay` goes through AppKit and sets the
  appearance on the way. The first window-server capture did (below).
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
that as readily as an eye can. The tool palette stays regardless — the mutation
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
of a long message belongs on a surface of its own, and nothing in this repository
builds that surface yet — §8 records what was learned by building one and taking
it out again.

**Streaming is on the palette because none of it is assertable.** A test can prove
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

**In a view controller, "laid out" means `viewDidAppear`, not `viewWillAppear`** —
the root `CLAUDE.md`'s "Size before content". The demo's tabs loaded in
`viewWillAppear` for a while, on the theory that a tab first gets a width when it
is first selected. It does not get one there: the view is 0×0 and not yet in the
window. So every row was measured at zero and corrected afterwards, and in an
editor opened on the right the rows that had been drawn from the zero-width pass
came out squashed or stretched. `EditorAreaTests.testATabAppearsAtItsFinalSizeAndNotBefore`
pins the premise.

This stays the host's job. The transcript could defer its own binding until it
has a width, and that was tried: it costs a state the host cannot see, mutations
that silently do nothing while in it, and a `numberOfRows` answered from two
different places. Parity with `NSTableView` (§1) is worth more than protection
from an ordering a host gets right once, in the ten lines where it mounts.

A long transcript loads by rendering the first screen, then feeding the
remainder in batches, **one batch per hop**. Each tick handles a batch small
enough to fit the frame budget, so the cost is spread across ticks instead of
landing in one.

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

### Past a few thousand rows, spreading the work is not enough

Hops divide one freeze into many; they remove none of it. Measured, ten thousand
rows of real markdown, five hundred to a batch: **12.47 s of main thread, worst
batch 665 ms.** Forty dropped frames, twenty times over. The window cannot be
scrolled or resized throughout.

**What `NSTableView` actually asks for, and it depends on how the rows arrived.**
Measured on rows of real markdown, counting the distinct rows the data source was
asked about:

| how the transcript was loaded | rows that end up measured |
|---|---|
| `reloadData()` | **all of them** — 50, 500, 2 000 and 10 000 rows each came out at 100% |
| `insertRows(at:warming:)` | all of them, by construction: a prepared batch is merged whole |
| `insertRows(at:)`, 500 to a batch | **60%** at 500 rows, **22%** at 10 000 — and it does not catch up, through neither further layout passes nor a scroll to the tail |

With `usesAutomaticRowHeights` off the table has to publish a document height, and
a `reloadData` gets there by asking about every row. An *insert* into a table that
already has one does not — it asks about a working set and extrapolates, which is
the third row above, and why with the first 400 rows short and the rest long the
published height came out **four times too small** until scrolling to the tail
forced the real numbers out.

An earlier version of this paragraph said the table never needs every height, and
that a ten-thousand-row `reloadData` asked 305 times. It does need them on that
path, and where 305 came from the note did not record. §8's "`heightOfRow` is asked
of every row at reload" was the accurate half, and the two sat here contradicting
each other until someone measured. **A number here with nothing to reproduce it is
a number to re-measure** — the same lesson as the one further down about an
unexplained cost attributed to the framework.

Two claims downstream turn on which path a host takes rather than on one number, so
read them that way: `prepareRows` **over-measures** against a plain batched insert
(ten thousand prepared against the ~2 200 that path asks for) and not at all
against `reloadData`; and `RowCache.entries(measuredAtWidthOtherThan:)`'s note that
a long transcript leaves most of itself unmeasured describes the batched-insert
path, where after a `reloadData` a width change invalidates the lot.

So `prepareRows(_:)` + `insertRows(at:warming:)` measure the batch off the main
actor first and hand the answers over, leaving the insert a cache merge. Same
transcript: **0.12 s of main thread, worst batch 11 ms** — inside a frame, so it
scrolls while it loads. `make demo-kit`'s two **Cold load** buttons are that
table, live.

Three things are worth knowing before reaching for it:

- **What is async is the *measure*, not the *insert*.** `insertRows` stays
  synchronous and total, because `transcriptView(_:rowAt:)` is answered by index
  with nothing cached in between: suspend between mutating the model and
  announcing it and, for that window, the table believes the old row count while
  the data source answers from the new one. An `async insert` would *create* the
  inconsistency it looks like it avoids. That rule is `NSTableView`'s and applies
  to a plain insert too.
- **Nothing else needs holding.** A batch is keyed on `TranscriptRow.ID`, so
  where its rows end up is not preparation's business: insert, remove, reload or
  resize the transcript while a batch is in flight and the batch is still filed
  correctly when it lands. This was not true when the batch was paired with an
  `IndexSet` by position — a prepend during the `await` discarded the whole
  batch, and a prepend is what loading history *is*. `insertRows(at:warming:)`
  is one call rather than a separate `warm(_:)` for a different reason: warming
  after the insert is a silent no-op, and fusing them makes that unwritable (§4).
- **The one thing a wrong case still costs.** `RowCache` believes an entry only
  as far as its `(content, width)` matches, so a stale or misdirected measurement
  re-measures rather than rendering wrongly — except that one string measures to
  two heights depending on whether it arrives as `.markdown` or `.userMessage`,
  and an entry filed under the wrong case is internally consistent, so nothing
  downstream objects. That is why the comparison is on whole
  `TranscriptRowContent` values rather than their text.
  `PreparedRowsTests.testAMeasurementPreparedAsTheWrongCaseIsNotUsed` covers both
  directions, and had to: it checked only one for a while and stayed green
  through a break of exactly this comparison, because the other direction happens
  to be caught by a pattern match instead.
- **The floor left standing is small and flat.** Measured on synthetic documents
  rather than the demo's corpus, so read the two columns against each other and
  not against the table above — ten thousand rows in batches of five hundred,
  positional cache against identity-keyed, same machine, same run:
  **119 ms of main thread against 31 ms**, worst batch **10.0 ms against
  2.5 ms**, and — the part worth the A/B — the positional figure *grew* across the
  load (2.3 → 10.0 ms) where the keyed one is flat (1.4 → 1.5 ms). That growth was
  recorded here for one commit as `NSTableView`'s bookkeeping being proportional
  to the rows it already held. It was not: it was this package splicing an array
  of `numberOfRows` elements on every insert. **An unexplained number attributed
  to the framework is usually one of ours.**

  What the identity cost instead is `removeRows` and `reloadData`, which now walk
  the data source to find which entries are orphaned: 0.7 ms → **5.1 ms** for a
  removal from ten thousand rows. Under a frame, on an operation that already
  re-tiles everything below it, and rare in a transcript — see
  `TranscriptView.sweepCache()`.

Two adjacent costs this does **not** address, both worth knowing before assuming
a long transcript is now solved:

- **`RowCache` keeps every height and only a budget of trees.** It used to keep
  every tree too, and a tree is ~470 KB of Core Text on the demo's corpus — ten
  thousand prepared rows came to **4.6 GB**. Now each row keeps its height for as
  long as it lives, the typeset trees are held up to `RowCache.residentBudget`
  (512 KB of source, ~45 MB) least recently drawn first to go, and
  `prepareRows` keeps a tree only for the tail of a batch that fits the budget:
  the same load is **~130 MB**, most of which is the host's own strings. An
  evicted row is typeset again when something draws it, rebuilt from source on
  the pool when the width changes, and built and dropped by a find — none of
  that on the main thread. See `RowCache`'s "Heights for every row, trees for a
  few".
- **A resize re-measures the whole working set, and that is nearly all of it.**
  `viewDidEndLiveResize` hands `noteHeightOfRows` every index; the table then
  re-asks about the few thousand it cares about. Measured on ten thousand rows of
  real corpus, three successive mouse-up resizes: **1.7 / 2.0 / 1.9 s** before
  `MarkdownMemo.remeasure(width:)` existed, **1.3 / 1.3 / 0.9 s** with it. The
  gap widens across the three because the width-only path only helps a row that
  has been measured before; a row reaching a width for the first time pays a full
  build either way.

  The number that said what to do next: replacing every height answer with a
  constant — measuring nothing at all — brought the same resize to **11–18 ms**.
  So `NSTableView`'s own tile, the visible-row rebind and everything else in the
  mouse-up path together are about 1% of it, and **measuring is the other 99%**.
  `prepareRows` gives a host no way to help, because the invalidation is the
  transcript's own — so the transcript does it itself, in
  `beginRemeasuringOffscreenRows(at:)`.

  **Where that landed.** Mouse-up now costs **17–44 ms** on the same ten thousand
  rows: the rows on screen are re-measured inside the pass that changed the
  width, and everything else is handed to the cooperative pool. Three numbers
  make the shape of it clear:

  | | |
  |---|---|
  | rows a width change actually invalidates | **300 / 700 / 1 100** of 10 000 |
  | that batch, measured across every core | **46 / 118 / 167 ms** |
  | main thread once it lands | **~0 ms** — every re-ask is a cache hit |

  The first row is why this is affordable at all: only a row something has
  already asked about has an entry, so a reader who has walked a long transcript
  end to end still leaves nine tenths of it unmeasured, and an unmeasured row is
  answered at whatever the width is when it is finally asked about. The batch is
  the transcript's *history*, not its length.

  **What the batch leaves is a window, and it grows with the history.** During it
  a row scrolled into gets its glyphs at the new width and its rectangle from the
  old one, since `NSTableView` caches heights and its `heightOfRow` takes no
  width. At 300–1 100 rows that is 50–170 ms and beneath noticing. On a
  transcript whose history really is the whole thing — a prepared cold load warms
  every entry, so a width change invalidates all ten thousand — it is **eight
  seconds**, and one batch at the end means eight seconds of it.

  So the correction is **published as it is produced**, and the rows are ordered
  **outward from the viewport**. Neither is an optimisation of the total; both
  shorten the only window a reader can meet, which is the time to correct the
  next screenful, and that does not grow with the transcript.

  | ten thousand rows, every one of them measured | |
  |---|---|
  | the walk that puts them in viewport order | **12–34 ms**, one `rowAt` per row |
  | first correction lands | **~190 ms** after the width change |
  | batches, and main thread across all of them | **77**, totalling **0.41 s** |
  | the largest single hop | **13 ms** |
  | the whole run | **8.3 s** on the pool |

  **Two ways to get this wrong, both measured, both invisible to every test.**

  - *Invalidating the whole transcript per batch.* `noteHeightOfRows` is not a
    note — the table re-asks inside the call, and with only the first seventy
    rows corrected the other 9 930 missed the cache and were measured on the main
    thread: **2 466 ms in one call**, worse than the freeze this replaced. Each
    batch invalidates its own rows; one full invalidation at the end, when
    everything is in the cache, costs **8–27 ms** and catches any row whose
    number moved meanwhile.
  - *Queueing every row into the task group at once.* `prepareRows` does exactly
    that, on the reasoning that the pool runs only core-count many and the rest
    are cheap task objects. That reasoning misses a group whose parent has to
    interleave main-actor hops: the parent is itself a job on the pool, so ten
    thousand runnable children starve it. Measured, it collected **78 results in
    10.8 s** and the remaining 9 900 in the 90 ms after the last child finished —
    the batching did nothing whatsoever. A sliding window of `activeProcessorCount`
    fixes it, and tightens the ordering as a side effect.

  **What paces the batches is the cost of applying one, not a clock.** A row
  count is the wrong currency (a paragraph against a four-hundred-line fence); a
  fixed slice is better and still wrong, because applying a batch is work
  proportional to the transcript on a main thread whose speed depends on the rest
  of the machine — one publish measured 5 ms quiet and 15 ms loaded. At a fixed
  8 ms slice that was **609 publishes and 1.9 s** of main thread. Collecting for
  twenty times what the last batch cost to apply pins the share at about 5%
  wherever it runs; on a quiet machine that is the ~100 ms interval the table
  above was taken at.

  Left standing on purpose, still: a row that scrolls in *during* the window and
  whose correction has not arrived. Self-healing from `viewForRow` is targeted
  but costs a frame at the wrong height, and cannot be done inline —
  `noteHeightOfRows` from inside the table's own layout re-enters it, and the
  recorded symptom was one pass measuring at two different widths. Ordering
  outward from the viewport is what made it not worth building; if the window
  ever grows back, that is the one to build.

  Worth recording because it was nearly mis-attributed twice. Entries that
  crossed the actor boundary *without their recipe* made the **first** resize
  after a cold load cost 3.1 s, and only the first — after which they had rebuilt
  a recipe and behaved like any other row; carrying the recipe (see
  `RowCache.Body`) removed that. And the parse a width change was running was
  once treated as cheap on the strength of `MarkdownMemo`'s own cost ordering,
  which is written about *streaming*: with shaping reused, parsing is not the
  cheapest item left but the largest, 60% against line-breaking's 32% and 2% for
  looking children up.

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

This is why the package has no paging protocol and no visible-range observation.
That apparatus exists to serve a sliding window
over an unbounded history — Telegram's `ChatHistoryLocation` is the reference
design, and it earns its complexity on chats with hundreds of thousands of
messages. A transcript is a bounded document whose rows' heights end up fully
resident — the trees behind them are what `RowCache` bounds (§6) — so the same
apparatus buys nothing here. Should a genuinely unbounded source turn
up, adding visible-range observation back is pure addition — don't add it
before then (§3).

## 7. Finding text is the package's, and the find bar is not

`find(_:)` / `findNext()` / `findPrevious()` / `endFind()`, a count reported
through `transcriptView(_:didUpdateFindMatches:isComplete:)`, and — for the rows a
host draws — one delegate question and one protocol. That split is §4's, drawn
where the knowledge is — the same line the hover band is drawn along, and for the
same reason.

**Why the search is on this side.** A host holds the markdown source, so it looks
like the party that can search. It is not: `**bold**` has no `bold` in it to match
against, a link's address is text no reader sees, and a hit expressed as an offset
into the source names nothing the transcript can highlight. What a hit *is* is a
range in a row's flat index space, and that space exists only once the row has been
built. So the search runs where the trees are.

**Why the find bar is not.** What a reader is told — the wording, whether a
still-climbing total is qualified, where the field sits, what ⌘G is bound to — is
product, and the find bar over each of the demo's transcripts
(`TranscriptWorkspace`'s `FindBarView`, §9) is one answer to it rather than this
package's. What crosses is the count, because it is the only part a host renders.
Not the hits: a position in one is an index into a tree the host has never seen,
and there is nothing to do with one but hand it straight back.

**`NSTextFinder` was the obvious parity move (§1) and was not taken.** It would
bring the find bar, ⌘F/⌘G/⌘E and the match counter for free, and
`NSTextFinderClient` is even shaped for discontiguous content —
`string(at:effectiveRange:endsWithSearchBoundary:)` is "my content is a sequence of
separately-addressable strings", and that boundary flag is this package's
"a match never spans two blocks". Three costs sank it, and they are the reasons to
re-read before anyone proposes it again:

- Its index space is **one global character offset across the whole content**, so
  it needs a prefix sum over row lengths and a (row, local index) ↔ global map,
  rebuilt on every insertion. That is precisely the positional bookkeeping keying
  `RowCache` on identity deleted, arriving back under a different name.
- `string(at:)` is a **synchronous main-thread pull**, and a row nothing has
  measured has no string until something parses it. There is no "not yet, ask
  again" in that protocol, so the freeze §6 spent its whole length removing comes
  back through it.
- `drawCharactersInRange:forContentView:` assumes a client that can draw an
  arbitrary range on demand, which fits `NSTextView`'s layout manager and not a
  table of recycled rows.

So the vocabulary is taken and the machinery is not, which is §2's standing shape. The
*look* is taken too — see "How a find looks" below — and so is the shape of what a
content view is asked: `TranscriptFindHighlighting` is `NSTextFinderClient`'s
`rects(forCharacterRange:)` and `drawCharacters(in:forContentView:)`, nothing more.

**A hit is a range, and that is what makes the rest cheap.** The flat index space
is a function of a row's content and no part of it depends on the width — the same
invariant `BlockView`'s selection rests on. So a resize moves every highlight to
where those characters are now with nothing recomputed, and a hit survives
insertions above it because it is filed under `TranscriptRow.ID` like everything
else here.

One consequence is worth stating outright because it looks like a bug: **a find
reads a document's `RowCache` entry on content alone, ignoring the width.** An
entry the cache would refuse to draw — measured before a resize, or still waiting
for its correction — answers a search exactly as well as a fresh one.
`cachedMeasured(for:width:)` with a `nil` width is that read, and it is the only one
in the store that skips the width check. A capped user message is the exception
that passes a width, for the reason two paragraphs down.

**Reading order, not outward from the viewport**, which is the opposite of what
`staleRowsOutwardFromViewport(at:)` chose. The two are racing different things: a
width correction has a *window* the reader can meet, so it starts where they are
looking; a find has an *ordinal*, and "4 of 51" only means anything if the fourth
hit is the fourth from the top, so hits arriving out of order would renumber
themselves under the reader as the walk filled in.

**The ordinal is a cache, not a counter.** It was a counter once — "the hits filed
so far are the hits before this one" — and that is true only of a transcript
nobody touches during the walk. A removal above the current hit left it one too
high ("3 of 2", and a ⌘G that stood still); a prepend mid-walk re-searched the rows
it pushed forward and counted them twice. So the selection is held by *where* it is
— a row identity and a range — and the number is worked out on demand by walking to
it, cleared by anything that can change what comes before it.

**The transcript can change under every `await`, and the walk is written for
that.** Its cursor lives on the find rather than in the loop, and every mutation
renumbers it the way it renumbers the scroll anchor. Rows inserted behind it pull
it back so they are searched; a slice out on the pool that a mutation renumbered is
dropped and taken again rather than filed against rows that have moved. Rows
`reloadRows(at:)` announces are searched again on the spot — the table is measuring
them anyway — so a streaming answer is found as it streams, and a rewritten one
loses the hits its old text had. Each row's hits are filed with the content they
were found in, and a row is only ever drawn with hits found in what it holds now.
`reloadData()`, after which any row may hold anything, walks the whole find again in
place: results stay up until replaced, the reader keeps their hit if it survived,
and nothing scrolls.

**Where the reader lands is a separate question from what order the walk runs
in**, and conflating the two was the first thing the demo caught. Selecting the
first hit the walk meets is one line and looks principled next to the paragraph
above; used once, it is obviously wrong — search for a word on the screen in front
of you and the transcript scrolls to the top of the history to show you a different
one. So the hit that selects itself is the first one **at or after the first
visible row**, and a query whose every hit is above the reader wraps to the first
when the walk finishes. A hit already wholly on screen is selected without the
transcript moving; one that is not is centred — **the hit, not its row**, which
is several screens tall when it is a long answer, so bringing the row's nearest
edge into view can leave the match a page away. The hit's rectangle comes from the
row's tree and the table's cell frame, not from a view, so a row nothing has tiled
answers as well as one on screen.

The cost of keeping reading order is that a reader deep in a long transcript waits
for the walk to reach them before anything is selected. That is bounded by the
scan, which after a `reloadData` is a cache read per row; if it ever stops being
beneath noticing, the direction is to walk from the viewport and wrap — and to
accept that the current hit's ordinal then shifts as the part above it fills in.

**A tree built to search is used and dropped.** Filing it in `RowCache` looks like
thrift and is a change of behaviour: the cache holds only a budget of trees (§6),
so one ⌘F over a transcript nobody has read would push every row through it and
evict the rows on screen to make room for rows nobody is looking at. What
outlives the tree is the range, and the one row a reader jumps to is re-measured on
arrival.

**A cut-short user message is searched only as far as it is shown.** `UserMessage`
caps its lines, and `ShapedText.typeset(width:limit:)` builds the last one over the
*whole* remainder before truncating it — so that line's range covers text that is
not on screen, and selection is deliberately allowed to reach into it ("copy what I
sent"). A find cannot take the same liberty: every index past the ellipsis reports
the same pen position, so a hit there is a rectangle of zero width — counted,
navigable, and invisible on arrival. The truncated line is therefore left out
whole, losing the visible part of one line, because Core Text does not report where
it cut. The better answer is to report such a hit and let the host open the rest
through `didActivateMoreInRow:`; it needs a host that has built that surface, and
§8 records what was learned by building one and taking it out again.

How far a capped message is shown depends on how its lines broke, which is a
function of the width — so this is the one row whose searchable text moves with a
resize. The find is walked again once the width settles (mouse-up, as with the
off-screen re-measure), and a user message's cached tree is read only at the width
the walk is matching at.

**A host's `.view` rows take part through two small seams, and only two.** Where the
matches are is `transcriptView(_:findMatchesOf:inRow:)`, on the delegate next to
`heightOfRow` and answered the same way — from the model, for any row, never by
building a view; `NSTableViewDelegate`'s `typeSelectStringFor:` is the precedent.
Showing them is `TranscriptFindHighlighting`, adopted by the row's view, and it asks
only what `NSTextFinder` asks of a content view: where a range is drawn, and its
glyphs drawn again on their own. The transcript does all the drawing — the dimming,
the lit matches, the current one's bubble — so a host's row looks exactly like the
transcript's, and a host writes no highlight, no colour and no appearance handling.
The transcript's own `BlockView` adopts the same protocol, so there is one path that
presents a find, whoever drew the row. The ranges are in the host's own index space;
the transcript counts them into the total and the ordinals, compares them to know
which is current, and hands them back — nothing else.

An earlier shape had the row draw its own highlights, told `setFindMatches(_:current:)`
after every bind. It worked, and it made every host implement a highlight, pick its
colours and get dark mode right — three things a host has no reason to have an
opinion on, and the first two it could only get subtly different from the
transcript's. It also could not have produced the dimming: that is drawn *over*
rows and between them, which no row can do. A hit in
a `.view` row is scrolled to by its row's nearest edge, since its geometry is the
host's. What was not added: a protocol for the host to *search* through (it already
has its model), a rectangle query for scrolling to a hit inside a tall host view, or
any options type. Each is a pure addition if a host ever needs it.

**What the demo is for here**, and it earned its keep in the first two minutes: it
found the landing rule above, and a find bar left showing "1 of 15" beside an empty
field. The second one is why `endFind()` reports rather than staying silent — the
callback means *this is the find's state now*, and a state a host is only sometimes
told about is one it has to track twice. Both were invisible to a suite that had
already verified every hit, every rectangle and every ordinal.

### How a find looks

AppKit's own, measured rather than recalled: an `NSTextView` with an incremental
find bar, captured through the window server (§5) in both appearances. **Light**
dims the content to 18% black — white comes out at 209 — and cuts every match out
of it. **Dark** does not dim at all, and outlines every match with a one-pixel white
rule instead. In **both**, the match the reader is on is a yellow bubble
(`findHighlightColor`) a little larger than its line, lifted by a shadow, with its
characters drawn again in black — in dark mode too, where the row's own are
near-white. The rule is drawn in light as well, where it vanishes against a white
page and is what keeps a match on a dark card — a code block, a bubble — from
reading as a hole into the window. Corners are rounded at 3 as Safari's are; the
text view's are square. That is the whole of the style, and `FindOverlayView` is
where it lives.

An earlier version drew hits as bands under the glyphs, inside each row, with a
warm low-alpha tint for dark mode because `findHighlightColor` under near-white
glyphs hid the word. The bubble answers the same problem the way AppKit does —
by drawing the characters again, dark — which is why the protocol asks a row to
draw its glyphs: that is the only way a bubble can put *dark* ones on its yellow
over a row that draws light ones.

**Where it is drawn is what makes it hold still.** The dimming covers rows and the
gaps between them, so it cannot be a row's; it is one view over the viewport. But a
view over the viewport that is moved *to* the rows on every scroll event is always
at risk of drawing a frame late — the swimming highlight — and AppKit can scroll
without the main thread's help. So the overlay is a **floating subview of the scroll
view, floating on the horizontal axis only**: `addFloatingSubview(_:for:)`, the
slot NSTableView's floating group rows use. AppKit keeps it above the document and
below the scroller, and carries it through every vertical scroll exactly as it
carries the rows — its coordinates are the document's. A lit match cannot leave its
text during a scroll; what the overlay has to keep up with is only what is *under*
it — which rows are on screen, where their matches are — and it covers the visible
rect with half a screen to spare either way, so a row arriving from past the edge is
lit before it is seen. `FindTests` asserts the property directly: scroll the clip,
lay nothing out, and the lit rectangle is still on the text.

**It reads the rows; nothing is pushed to them.** The overlay asks, at layout, for
the rows on screen and their matches — a question rather than a stored list, the
way a table asks its data source — and every reason to ask again reaches
`needsLayout`: the table re-tiling (`TranscriptTableView` reports `tile()` and
`layout()`), a row view arriving or leaving, a row rebound to new content, the find
changing, the clip moving. The overlay sits after the clip in the scroll view's
subviews, so a layout pass reaches it after the rows have moved rather than before.
A recycled view has nothing stale to carry, because it was never handed anything.

**The pop plays when the reader moves, not when the layout does.** The bubble grows
and settles once when the current match changes — the find indicator's bounce, how
the eye finds where it has been taken — and not on a scroll or a streamed row that
lays the same match out again. Reduce Motion turns it off.

What still needs eyes is what no assertion has an opinion about — that the
dimming reads as AppKit's, the rule on a dark card, the black characters landing on
the row's — and `FindPresentationSnapshotTests` captures exactly that in both
appearances.

## 8. The other side of the seam: `TranscriptMedia`

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
scrolls under — `contentInsets`, the demo's tool palette, `LinkTooltip`. Worst of all
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
- **`ImagePreviewView`** — what opens into it, answering the one requirement
  `MediaOverlayContent` asks: given the space, what rectangle do you want.

### The layout pass opens files, and that is allowed to stand

`heightOfRow` → `ImageGridView.height` → `MediaImageStore.size(of:)`, and on a
cache miss that last step opens the file. Synchronous I/O inside a layout pass,
which the project rules otherwise forbid. Kept deliberately, so here is the
measurement rather than a claim:

| on this machine, settled files | median | p90 |
|---|---|---|
| `open` + read 4 KB, **no ImageIO at all** | 350 µs | 400 µs |
| `CGImageSourceCreateWithURL` | 295 µs | 360 µs |
| `CGImageSourceCopyPropertiesAtIndex` | 63 µs | 68 µs |
| `size(of:)`, cold | **~400 µs** | ~480 µs |
| `size(of:)`, warm (a `[URL: CGSize]` read) | 0.1 µs | — |

The control line is the one that matters: **the cost is touching the filesystem,
not ImageIO.** `CopyProperties` is 63 µs and is flat in the file — an 8 KB PNG and
a 1.9 MB JPEG measure the same — so the "header only, flat in the picture's size"
claim in `MediaImageStore` is right. What that comment's 0.19 ms understates is
that its loop re-measured one URL; in production each URL takes the cold path
exactly once, and once is 0.4 ms.

And it is once per **row in the transcript**, not per row on screen:
`NSTableView` needs the document height, so `heightOfRow` is asked of every row at
reload. Probed on the demo — 11 picture rows, all 11 measured before anything was
scrolled.

So the bill is *every picture in the transcript* × 0.4 ms, in one pass, on the
main thread. The demo is ~26 pictures ≈ 10 ms, a frame and a bit. The judgement
call is that a real transcript does not hold enough pictures for the next order of
magnitude, and that is the whole of why nothing was built.

**If it ever does**, the fix is not a cache — it is already cached — it is moving
the read off the pass: a `prepare(_ urls:)` on the store that a host calls when the
*message* arrives, long before layout, leaving `size(of:)` a warm dictionary read.
Not "answer `fallbackSize` on a miss and re-lay-out when it lands", which would
undo the property above that a picture row's shape is settled before anything is
fetched and never revised under a reader.

`MediaOverlayContent` keeps its one requirement despite having one implementer,
and that is not the same call as the `inkFrame` one above. There the value was
threaded through a seam **no consumer had reached for**; here the shell genuinely
has to ask its content how big it wants to be, and inlining the question fuses a
window into an image view. A seam whose question is real survives having one
answer.

**A second content was built here and taken out.** `MessagePreviewView` — the
rest of a cut-short user message, on the same darkened surface — worked, and
nothing ever opened it: the transcript reports `didActivateMoreInRow:`, the demo
deliberately does not implement it (§5), and the app is not wired at all. So it
was a finished component with no caller, which is §3's rule, and it went the same
way `inkFrame` did. Three things from it worth having when it comes back:

- **Do not mount a second `TranscriptView` with one uncollapsed row**, which is
  fewer lines and inherits the typography exactly. A row is painted onto
  `SurfaceLayer`s sized to the row and split by paint phase, not by height; with
  the line cap removed, a pasted file's row is as tall as the file and its backing
  store goes with it. `NSTextView` lays out by visible range, so length stops
  being a question, and selection, find and copy arrive rather than being
  re-earned. The two renderers agree without sharing code because `UserMessage` is
  plain text on purpose.
- **Its face is larger than the transcript's and is not derived from it.** A row
  in a list is read in passing at a size chosen against its neighbours; a column
  alone on a darkened screen is read at length. Two problems, two constants — a
  delta would tie them together and neither would be right.
- **Measure it in a throwaway layout stack.** `widthTracksTextView` overwrites
  whatever `containerSize` was set, so asking a configured text view how tall it
  wants to be answers one line. A separate `NSLayoutManager` +
  `NSTextContainer` fixed at the target width is what gives the real height.

The same reasoning that put the image case out of the vocabulary is the reasoning
that fills this target. When something new arrives that seems to need a renderer
change, the first question is whether it is a picture-shaped problem: presentation
with product decisions in it, and a model the renderer would have to borrow. If
so it belongs here, and costs the renderer nothing.

## 9. Editors side by side: `TranscriptWorkspace`

A third target and product: an IDE-shaped area of up to two editors, left and
right, each with its own tabs — what the demo is built on, and what a host with
more than one transcript open can mount. **It depends on nothing in this package**,
not even `TranscriptKit`, and that is the point of its being a target: a tab holds
any `NSViewController`, and the compiler guarantees the split cannot reach into
what it holds. The transcript does not know it is in a tab, and nothing in it
changed for this except two bugs this made visible (below).

```
EditorAreaViewController      NSSplitViewController — the divider, which editor is active
└─ EditorGroupViewController  one per editor — its tab bar, and an NSTabViewController
   └─ NSViewController        one per tab — anything; never looked inside
```

**Everything structural is AppKit's, and the choices are the whole design.**

- **The split is an `NSSplitViewController`.** Dragging, the cursor, minimum
  widths and accessibility come with it — and so does something that matters for
  a transcript: *a divider drag is a live resize.* Measured, every view under it
  gets `viewWillStartLiveResize()` / `viewDidEndLiveResize()` and reports
  `inLiveResize` throughout, exactly as a window-edge drag does. So §6's
  "mid-drag, only the rows on screen" applies to the divider with nothing here
  knowing it exists. `EditorAreaTests` asserts it.
- **The tabs are an `NSTabViewController`** in `.unspecified` style, so a tab is
  an `NSTabViewItem` carrying a child view controller, **whose view is not loaded
  until its tab is first selected** and is out of the window whenever another tab
  is. Ten tabs cost one on-screen editor. A tab's label is the item's, which
  follows its view controller's `title`, and the bar follows the label by KVO.
- **The tab bar is built from what `NSSegmentedControl`'s `.tabs` role is made
  of**, because its segments cannot move and Xcode's drag moves a tab. The track is
  `secondarySystemFill`, the selected tab an `NSGlassEffectView` inset 2 points in
  its tab; measured against the control in the demo, the selected tab matches it
  pixel for pixel — glass edges, icon and title, and their colour — and the system
  colours and the glass carry the dark appearance and an inactive window. It
  replaced the segmented control only for the drag: measure against the control
  before changing how a tab looks.
- **A tab is a view placed by two constraints**, its leading edge and its width, one
  view per tab identity so a reorder moves views instead of relabelling them. A
  slide animates the two constants through their animators, which lays the tab out
  again on every frame. `animator().frame` looked like the obvious call and is
  wrong here: on a layer-backed view it animates the layer and lays the content out
  once, at the final size, so a tab changing width showed its glass at the end
  width at once and its title jumping ahead and sliding back.
- **The delegate is AppKit-shaped**: `EditorAreaViewControllerDelegate` has
  `editorArea(_:didActivate:)` and `editorArea(_:willClose:)`, both defaulted. The
  second is the `prepareForRemoval()` hook the project rules ask of a container —
  a tab's owner stops its stream or its load there, before the view controller
  leaves the tree.

**Behaviour, Xcode's unless noted.** A new tab selects itself. Closing the selected
tab selects the one after it. The last tab of the right editor closes that editor;
the last tab of the only editor leaves it empty, never gone. Pinned tabs come first,
as wide as their titles, with no close button, and survive Close Other Tabs; the
first `numberOfPinnedTabs` items *are* the pinned ones — a count, not a flag per
tab, because the invariant is the order. Along its bar a dragged tab stays in the
bar under the pointer, and a neighbour whose middle its edge passes slides into the
place it left, never across the pinned boundary; let go, it settles into its own.
Dragged far enough above or below, it leaves as a drag session carrying a capsule
of its title, and the tabs it left close up. Over a bar the tabs part where it
would drop, and it drops into the gap; dropped on the other editor's content it
goes to the end;
dropped on the trailing half of its own editor's content it opens a new editor on
the right (refused for an editor's only tab — that would move the same layout
over). **Which editor is active follows the reader**: the one last clicked
anywhere inside, by a local event monitor that only looks, or the one holding the
first responder, by KVO — two signals, because a click on a transcript's margin
moves no focus and Tab moves focus without a click.

**What a tab's owner has to route itself.** ⌘F is not a responder-chain action a
view controller answers: measured, `performTextFinderAction:` is answered by
`NSTextView` (the field editor) and by nothing on the way up from a transcript. So
the demo's Find menu targets its window controller, which sends it to the active
editor's tab. That is a host's answer and belongs in the host.

**The find bar**, `FindBarView`, is a view and a delegate: it reports the query and
`NSTextFinder.Action`s and is told the count, and knows nothing about what it finds
in. Xcode's Aa, Contains/Begins With and the replace toggle are **not there**,
because `find(_:)` takes no options (§7, §3) — controls that do nothing are worse
than none. Return and ⇧Return step, Escape and Done hide, the count reads
"No matches" / "1 match" / "N matches", and the arrows are enabled only with
something to step to.

**Two transcript bugs that editors made visible**, fixed in the transcript and
tested there — neither is the workspace's to work around:

- A width change that is not a drag — an editor opening beside this one — let
  AppKit animate the visible rows to their new heights, with glyphs already laid
  out for the new width: text that squashed and sprang back. The width path now
  opens `mutate`'s suppressed animation group
  (`ResizeRemeasureTests.testAWidthChangeOutsideADragDoesNotAnimateTheRows`, which
  reads the layers' `animationKeys()`).
- The find overlay is taller than the viewport on purpose, and nothing clipped it,
  so its dimming spilled over whatever sat above the transcript — the find bar and
  the tab bar. Invisible while the search field lived in the window's toolbar. The
  scroll view clips now (`FindTests.testTheDimmingStaysInsideTheTranscript`, a pixel
  read from the composited window).
