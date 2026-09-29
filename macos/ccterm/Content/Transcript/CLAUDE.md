# Transcript tab

A session transcript, read-only, and the documents it opens beside itself. The design is `design/transcript/` (README + 01–07, and `preview.js` / `preview.css` for exact values); build to it one to one.

## Layers

```
Page/        model — messages → TranscriptPage (entries, runs, work lines, documents). No AppKit.
Drawing/     what rows and documents both draw: the tile, StyledText's fonts and colours.
Rows/        a page's entries → PageRow (pure), and the views that draw `.view` rows.
Documents/   what opens beside: DocumentViewController (shell) + bodies.
TranscriptViewController   the tab: page, disclosure, selection, ↑/↓, reveal.
```

Dependencies point down only, and siblings don't know each other: `Drawing/` reads only `Page/`; `Rows/` reads only `Page/` and `Drawing/`; `Documents/` reads `Page/`, `Drawing/` and AgentSDK's tool types (a body reads its call's typed input and output); the tab reads `Page/` and `Rows/`; `Page/` reads only `AgentSDK`. `MainSplitViewController` is the coordinator — the one place that knows both the tab and the documents: it creates tabs, routes what one asks of the other, and makes a subagent's conversation for a document (`DocumentBodyFactory.makeConversation`). `make arch` must show no edge beyond these.

## Rules

- **Words are decided in `Page/`** — and a document's in `DocumentHeader` and `DocumentMarkdown`, the pure worded types in `Documents/`. Every sentence, label and stat is built there, localized, as `StyledText` (words plus the distinctions a view draws: noun, code, added, removed, failure). A view picks fonts and colours for those styles; it never composes wording or formats a number. Tests assert on the words without AppKit. A view keeps only fixed control copy (*Allow*, *Deny*, *Submit*, *Show N more*, *Interrupted*, *Summary*); a sentence, a stat, a date or anything read out of a call's input is the page's (`Approval`, `Question.Item`, `LocalCommand.title`, `SessionDivider.label`, …).
- **Row views are drawn from page values, never from the SDK** — `Rows/` doesn't import `AgentSDK`. A document body may read its call's typed input and output (`use.input(as:)`, `result?.toolOutcome(_:)`) — mirroring every tool in `Page/` would buy nothing — but its header and stats are worded in `DocumentHeader`.
- **`Page/` types are `nonisolated`** (the app defaults to `MainActor`); pages are built off the main actor.
- **TranscriptKit draws what it can.** Replies, prompts, a voice's words (a blockquote), a plan, and every markdown document are TranscriptKit `.markdown` / `.userMessage` rows or a `TranscriptView` — no second renderer. Only work lines, captions, capsules, dividers, questions and approval controls are `.view` rows.
- **One row per line.** A run's line, each item, *Show N more* and the approval card are separate rows (`PageRow.Part`); expanding is inserting rows. TranscriptKit forbids animating row geometry, so nothing slides.
- **Row views keep `PageRowView`:** `static height(for:width:)` from the model alone, idempotent `configure(with:)`, events up through `PageRowViewDelegate` by id. `PageRow+View` is the one switch from row kinds to views. `PageRowViewContractTests` holds every row view to it — laid out at the height it declares, nothing outside or cut, nothing moved by reconfiguring, selecting or flashing; a new row view adds its fixtures there.
- **A row acts on press, then lets the transcript take focus.** Handle the click in `mouseDown` (clickCount 2 is a double-click → `pinned`), then call `super.mouseDown(with:)`, which reaches the table and makes it first responder — that is what keeps ↑ / ↓ with the transcript after a document opens beside it. Controls inside a row (a link, the chevron, a button) are the exception: they handle their own tracking.
- **Live states stay in the model; the builder yields settled ones**, plus `running` for the calls of the last assistant turn. Approval cards, a plan's decision and a question's controls are drawn from `.waiting` states no transcript on disk has; their answers reach `rowView(_:decide:for:)` / `approvalBarView(_:decide:for:)`, which log and stop until a live session exists.
- **A document is a shell and a body.** `DocumentViewController` loads the `Document` when it first appears, words the jump bar (`DocumentHeader`), shows an approval bar while the call waits, and embeds the body `DocumentBodyFactory` picks. A body is an `NSViewController`: command, source (change / new file / read), markdown, or — for a subagent whose conversation is on disk — a `TranscriptViewController` on `subagents/agent-<id>.jsonl`.
- **A document's tab identifier is its `DocumentReference`** (transcript URL + id), so history rebuilds it (`editorArea(_:tabViewItemWithIdentifier:)`) and a second open finds it.

## Adding a tool

- **A tool of an existing kind** is one line in `ToolKind.init(_:result:)`. Its row reads the kind's input keys (`command`, `file_path`, `pattern`, `url`, `query`, `description`) and its meta falls back to nothing, so it reads right before it gets words of its own; give it those in its kind's branches of `WorkLineWriter` when it needs them.
- **A new kind** is a design change (the kinds are the design's closed vocabulary, README "Kinds"). Add the `ToolKind` case and follow the compiler: every place that gives a kind its words, tile or document switches over it exhaustively — no `default:` there.
- No registry or per-tool protocol: tools are added far more often than kinds, and a tool is one line.

## Reuse before adding

| Need | Use |
|---|---|
| A kind's tile, any state | `ToolTileView` |
| `StyledText` on screen | `attributedString(font:color:)`; `NSColor.addedText` / `.failureText` |
| A line of work (run, item, news) | `WorkLineRowView` |
| A voice's or plan's words | `.markdown` row (`PageRow.quoted` for a voice) |
| A document of words | `MarkdownDocumentViewController` + `DocumentMarkdown` |
| Numbered monospaced lines | `NumberedLinesView` |
| A subagent's conversation | `TranscriptViewController` |
| The sidebar's party glyphs and coral | `.sidebarAgent`, `.sidebarSession`, `.sidebarWorkflow`, `.sidebarCoral` |
