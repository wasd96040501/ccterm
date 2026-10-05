# TranscriptKit

Standalone Swift package: a chat transcript view for AppKit, `TranscriptView`, driven by a data source. The app's transcript tabs are built on it. `README.md` has the public API tour; this file holds the rules for changing it.

| Target | What | Rules |
|---|---|---|
| `TranscriptKit` | The renderer: `TranscriptView`, data source / delegate, markdown → blocks, `RowCache`, selection, find | this file + [Sources/TranscriptKit/CLAUDE.md](Sources/TranscriptKit/CLAUDE.md) (internals) |
| `TranscriptMedia` | Pictures: mosaic layout, image grid row, full-screen viewer. Depends on **nothing** | [Sources/TranscriptMedia/CLAUDE.md](Sources/TranscriptMedia/CLAUDE.md) |
| `TranscriptWorkspace` | Xcode-style editor area (split + tabs). Depends on **nothing** | [Sources/TranscriptWorkspace/CLAUDE.md](Sources/TranscriptWorkspace/CLAUDE.md) |
| `TranscriptKitDemo` | The demo app — where what tests can't assert gets looked at | [Sources/TranscriptKitDemo/CLAUDE.md](Sources/TranscriptKitDemo/CLAUDE.md) |
| `TranscriptKitTests` | The package's own suite | [Tests/TranscriptKitTests/CLAUDE.md](Tests/TranscriptKitTests/CLAUDE.md) |

Run from the repo root: `make test-kit [FILTER=<Class>]` (`swift test`) and `make demo-kit` (`swift run TranscriptKitDemo`). The package carries its own `.lproj/Localizable.strings` (see `Package.swift` for why not `.xcstrings`).

## 1. Mirror `NSTableView`

The public surface is `NSTableView`'s, name for name and signature for signature: `numberOfRows`, `reloadData()`, `insertRows(at:withAnimation:)`, `removeRows(at:withAnimation:)`, `moveRow(at:to:)`, `reloadRows(at:)`, `noteHeightOfRows(withIndexesChanged:)`, `rect(ofRow:)`, `row(for:)`, `makeView(withIdentifier:…)`. The data source says *what* the rows are; the delegate says *how they appear*. A host that has written an `NSTableViewDataSource` already knows the API and can check it against Apple's docs.

Before adding or renaming anything public, look up the AppKit counterpart (`make appkit-doc SYMBOL=NSTableView`) and take its spelling unless §2 applies.

## 2. Deviate where AppKit is wrong — and say why in the doc comment

A deviation with no reason in its doc comment is a bug: restore parity or write the reason. Standing deviations:

- **`makeView(withIdentifier:make:)`** returns a generic `V` from a factory closure instead of `owner: Any?` → `NSView?`. AppKit's shape serves nib loading; in code it forces `as? Foo ?? Foo()` plus a manual `identifier` assignment, and forgetting that assignment silently disables recycling.
- **`heightOfRow(_:width:)`** takes a `width`: the transcript derives the content width itself, so it has to hand it to the host.
- **`customSpacingAboveRow`** is `NSStackView.customSpacing(after:)` on the other side of the row, as ExactList's (its G7): rows disclosed under one that stays carry their own gap, so nothing around them is noted.
- **`scrollToRow(at:scrollPosition:)`** instead of `scrollRowToVisible(_:)`, which can't express a landing position; the shape is `NSCollectionView`'s, with `scrollRowToVisible`'s behaviour as `.nearestEdge`.
- **No `frameOfCell(atColumn:row:)`** (no columns) and **no `didAdd`** (`viewForRow` already is that moment).
- **`performBatchUpdates(anchoring:_:)` instead of `beginUpdates()` / `endUpdates()`** — `NSCollectionView`'s name, because a batch here also says what holds still (`Anchoring`): `.row(r)` keeps the row the reader acted on under the pointer, which `NSTableView`, holding the scroll offset, can't express.
- **No `NSTextFinder`.** Its single global character index needs a prefix sum rebuilt on every insert; `string(at:)` is a synchronous main-thread pull with no "not yet"; `drawCharacters(in:forContentView:)` assumes on-demand drawing of any range. The vocabulary and the look are taken (Sources/TranscriptKit/CLAUDE.md § Find), not the machinery.

## 3. Nothing speculative

Public API lands when a caller needs it. The rest of `NSTableView`'s surface — `rows(in:)`, `moveRow(at:to:)`, the selection family — is added the day something calls it. A protocol requirement or parameter with one implementer and no consumer is speculation too; take it out until a real caller defines its shape.

## 4. Don't re-grow the old renderer

The renderer this replaces reached ~18 000 lines because every new kind of content meant a new block kind, layout file and enum case in several switches. Three rules keep that from recurring:

- **The content vocabulary is closed.** `TranscriptRowContent` has three cases (`.markdown`, `.userMessage`, `.view`) and gains none — a case's payload may grow (`.userMessage` carries tokens and a pending flag; the bubble draws a token as an inset of its own colour), a fourth case may not. Anything richer — tool cards, attachments, pictures, progress rows — is `.view`, drawn by a host `NSView`. If a new case seems needed, the answer is a `.view` (pictures are: see `TranscriptMedia`). A case with no renderer behind it is not pending work; remove it.
- **Collaboration goes through the two protocols.** No `onSomethingChanged` closures between internal types, no `@Observable` fields for the host to watch. A new host-facing event is a delegate requirement with a default implementation.
  - **Context menu:** `transcriptView(_:menu:forRow:)` receives the menu the transcript would show and returns the one to show. The transcript contributes and executes only what it can implement itself (today, Copy — it depends on a selection only the transcript sees); host items (Quote, Retry, …) carry their own target/action and never route back. The menu is built fresh per click; `.view` rows never reach the hook, since AppKit already asks the host's view for its menu.
  - **Selection** has no API; a host sees it only through Copy. It is the transcript's (`TextSelection`, held by row identity and renumbered by every mutation).
  - **Hover and More:** the transcript draws the link band; the host decides what, if anything, to say about it (`transcriptView(_:didHover:at:inRow:)`). Pressing a truncated message's More reports `transcriptView(_:didActivateMoreInRow:)` with **the row only** — the host already owns the message. It must open a separate surface, never expand the row in place (a long paste would unfold under the reader).
- **Ordering contracts live in the API shape, not in prose.** `dataSource` doesn't refresh on assignment — the host calls `reloadData()`. `insertRows(at:prepared:)` fuses insert and warm because warming after an insert would silently do nothing. When an order matters, make the wrong order unrepresentable or harmless rather than documenting it.

## 5. How a host loads

- **Mount, lay out, then load:** add the view, activate constraints, `layoutSubtreeIfNeeded()`, then `reloadData()`. Loading first measures every row at width zero, then again at the real width. In a view controller, "laid out" means `viewDidAppear` (see `macos/CLAUDE.md` "Size before content"; `EditorAreaTests.testATabAppearsAtItsFinalSizeAndNotBefore`). This stays the host's job — deferring binding inside the transcript would add hidden state and no-op mutations, which costs more than parity with `NSTableView` saves.
- **Mutations commit before the call returns** (ExactList U1): each on its own, or together — one commit, one motion — inside `performBatchUpdates`. The async hop between batches is what spreads work across frames. Scroll anchoring keeps prepends above the viewport invisible.
- **Past a few thousand rows, prepare off-main:** `let p = await transcript.prepareRows(rows)`, then (no `await` in between) mutate the model and `insertRows(at:prepared: p)`. The *measure* is async; the insert stays synchronous and total, because suspending between model change and announcement makes the list and data source disagree. Prepared batches are keyed by `TranscriptRow.ID`, so any mutation may happen while one is in flight.
- **Streaming is `reloadRows(at:)` with the whole source every time — there is no delta API.** The data source is a pull model (the host holds the whole string anyway), markdown doesn't compose by appending (a later fence or delimiter row rewrites earlier lines), streams also rewrite and retract, and passing a Swift string is a retain. The increment is derived inside (`MarkdownMemo`). *What* to hand over mid-stream (e.g. holding back an unclosed fence) is host policy — the app's is `StreamingMarkdownCommit`.
- **No paging protocol or visible-range observation.** A transcript is a bounded document; row heights stay resident and `RowCache` bounds the trees. Add visible-range observation only if a genuinely unbounded source appears (§3).
