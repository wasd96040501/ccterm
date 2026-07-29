# TranscriptKit

Standalone Swift package: one AppKit view, `TranscriptView` — a chat
transcript driven by a data source.

## 1. Mirror `NSTableView`

The public surface is `NSTableView`'s, name for name and signature for
signature: `numberOfRows`, `reloadData()`, `insertRows(at:withAnimation:)`,
`removeRows(at:withAnimation:)`, `noteHeightOfRows(withIndexesChanged:)`,
`noteNumberOfRowsChanged()`, `beginUpdates()` / `endUpdates()`,
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
- **Ordering contracts live in the API shape, not in prose.** `dataSource`
  deliberately does not refresh on assignment; the host has to call
  `reloadData()`, so "wire it up, then load" cannot be got wrong by accident.
  When a sequence has to run in a particular order to be correct, make the
  wrong order unrepresentable or harmless. Don't write the order down and add
  a test to guard the writing.

## 5. How a host is expected to load

Not a rule about this package's code — a note on how hosts drive it, recorded
here so nobody reaches for machinery that isn't needed.

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
