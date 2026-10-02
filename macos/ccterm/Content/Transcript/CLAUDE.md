# Transcript tab

A session transcript, read-only, and the documents it opens beside itself. The design is `design/transcript/` (README + 01–07, and `preview.js` / `preview.css` for exact values); build to it one to one.

## Layers

```
Page/        model — messages → TranscriptPage (entries, runs, work lines, documents). No AppKit.
Drawing/     what rows and documents both draw: the tile, StyledText's fonts and colours.
Rows/        a page's entries → PageRow (pure), and the views that draw `.view` rows.
Documents/   what opens beside: DocumentViewController (shell) + bodies.
TranscriptViewController   the tab: page, disclosure, selection, reveal; the composer (ComposerView) on a session's own tab.
TranscriptTab              the feature's door: a tab's identity, and the one place its tabs are built.
```

Dependencies point down only, and siblings don't know each other: `Drawing/` reads only `Page/`; `Rows/` reads only `Page/` and `Drawing/`; `Documents/` reads `Page/`, `Drawing/` and AgentSDK's tool types (a body reads its call's typed input and output); the tab reads `Page/` and `Rows/`; the root (`TranscriptTab`, the tab) reads `Documents/` too, to build a document's tab, and `SessionStore` (`ccterm/Sessions/`), the one way to a session — read and talk; `Page/` reads only `AgentSDK`. `Documents/` never names the root or the store: a document has no delegate, and what it needs from outside (`load`, `makeConversation`, `showInTranscript`, `decide`) arrives as closures. `MainSplitViewController` is the coordinator and decides **placement only** — which editor a tab opens in, what is focused, what the window shows. The feature builds its tabs: the app names only `TranscriptTab` and `TranscriptTabDelegate` from it, and hands it the `SessionStore` (`TranscriptTab.makeItem` wires a subagent's conversation, the document's `makeConversation`, as a transcript tab with the same delegate and store, without a composer). `make arch` must show no edge beyond these.

## Rules

- **Words are decided in `Page/`** — and a document's in `DocumentHeader` and `DocumentMarkdown`, the pure worded types in `Documents/`. Every sentence, label and stat is built there, localized, as `StyledText` (words plus the distinctions a view draws: noun, code, added, removed, failure). A view picks fonts and colours for those styles; it never composes wording or formats a number. Tests assert on the words without AppKit. A view keeps only fixed control copy (*Allow*, *Deny*, *Submit*, *Show N more*, *Interrupted*, *Summary*); a sentence, a stat, a date or anything read out of a call's input is the page's (`Approval`, `Question.Item`, `LocalCommand.title`, `SessionDivider.label`, …).
- **Row views are drawn from page values, never from the SDK** — `Rows/` doesn't import `AgentSDK`. A document body may read its call's typed input and output (`use.input(as:)`, `result?.toolOutcome(_:)`) — mirroring every tool in `Page/` would buy nothing — but its header and stats are worded in `DocumentHeader`.
- **`Page/` types are `nonisolated`** (the app defaults to `MainActor`); pages are built off the main actor.
- **TranscriptKit draws what it can.** Replies, prompts, another agent's words (a blockquote), a plan, and every markdown document are TranscriptKit `.markdown` / `.userMessage` rows or a `TranscriptView` — no second renderer. Only work lines, captions, capsules, dividers, questions and approval controls are `.view` rows.
- **One row per line.** A run's line, each item, *Show N more* and the approval card are separate rows (`PageRow.Part`); expanding is inserting rows: one batch anchored on the run's line (`.row(first)`, or the clicked row for *all*), with `.effectGap`, so the line holds still and the rows below slide.
- **A row's box is its content; the gap above it is the list's.** A row view pads nothing above or below itself — except a line of work, whose box is its hover (28 pt at both levels, the words `WorkLineRowView.air` in from top and bottom), so the hover and the click reach the same box; that air is part of the gap. Two levels (design README "Spacing"): the transcript's gap between entries, less a line of work's air on either side, and `PageRow.spacingAbove(after:)` for what a line discloses (0) and the approval card (6), answered through `customSpacingAboveRow`. A disclosed row carries its own gap, and every row a run ends on has the same air, so opening and closing notes nothing; a prepended chunk notes the row it lands above.
- **Row views keep `PageRowView`:** `static height(for:width:)` from the model alone, idempotent `configure(with:)`, events up through `PageRowViewDelegate` by id. `PageRow+View` is the one switch from row kinds to views. `PageRowViewContractTests` holds every row view to it — laid out at the height it declares, nothing outside or cut, nothing moved by reconfiguring, selecting or flashing; a new row view adds its fixtures there.
- **A row acts on press; a press that opens a document gives it the focus.** Handle the click in `mouseDown` (clickCount 2 is a double-click → `pinned`). A press that opens a document stops there: the coordinator hands the focus to the document's tab, so ⌘W closes what was just opened. Any other press calls `super.mouseDown(with:)`, which reaches the transcript and makes it first responder. Controls inside a row (a link, the chevron, a button) handle their own tracking.
- **A tab follows its session; it never asks whether it is live.** `SessionStore.states(at:)` gives a session at rest (one value) or live (every change, newest only); each state becomes a page off the main actor. The first page is shown as a reader's load (last screen, then history in chunks); later ones are applied as `PageRow.changes` in one batch. The next state is pulled only after a page is shown.
- **Live states come from the session's state, not from the file.** The builder yields settled states, plus `running` for the calls of the last assistant turn; over a live state it adds `.waiting` for a call with a pending request, `.preparing` for a streaming call, and the streaming reply under the id its finished block will get. Answers (`pageRowView(_:didDecide:forCall:)`, `approvalBarView(_:didDecide:forCall:)`) become a `PermissionDecision` in `Page/` (`Decision.permissionDecision(for:)`) and go to `SessionStore.respond(toCall:at:with:)`.
- **A document is a shell and a body.** `DocumentViewController` loads the `Document` when it first appears and follows it while its call is still going (`Document.isLive`), words the jump bar (`DocumentHeader`), shows an approval bar while the call waits, and embeds the body it picks itself (`makeBody(for:)`, which also builds the subagent conversation). It has no delegate and names no root type; *Show in Transcript* is a closure it is given. A body is an `NSViewController`: command, source (change / new file / read), markdown, or — for a subagent whose conversation is on disk — a `TranscriptViewController` on `subagents/agent-<id>.jsonl`.
- **A tab's identifier is a `TranscriptTab`** — `.transcript(URL)` or `.document(DocumentReference)` (transcript URL + id) — so history rebuilds it (`editorArea(_:tabViewItemWithIdentifier:)`, decoded with `TranscriptTab(identifier:)`) and a second open finds it. A tab asks its host through `TranscriptTabDelegate`: *open* hands over an identity and a `makeItem` the host calls only if no such tab is open; *reveal* selects the transcript's tab and shows an item in it.

## Adding a tool

- **A tool of an existing kind** is one line in `ToolKind.init(_:result:)`. Its row reads the kind's input keys (`command`, `file_path`, `pattern`, `url`, `query`, `description`) and its meta falls back to nothing, so it reads right before it gets words of its own; give it those in its kind's branches of `WorkLineWriter` when it needs them. `WorkLineWriter` is used only inside `Page/`; a document's header and body reach for the small Page values it shares (`Tile(calls:)`, `ToolCall.toolName`, `TimeInterval.durationText`, `String.firstLine`) instead.
- **A new kind** is a design change (the kinds are the design's closed vocabulary, README "Kinds"). Add the `ToolKind` case and follow the compiler: every place that gives a kind its words, tile or document switches over it exhaustively — no `default:` there.
- No registry or per-tool protocol: tools are added far more often than kinds, and a tool is one line.

## Reuse before adding

| Need | Use |
|---|---|
| A kind's tile, any state | `TileView` |
| `StyledText` on screen | `attributedString(font:color:)`; `NSColor.addedText` / `.failureText` |
| A button (Allow, Deny, Submit, Approve, Open…) | `PillButton` — the design's `.btn`, with its `kbd` hint |
| A line of work (run, item, news) | `WorkLineRowView` |
| Another agent's or a plan's words | `.markdown` row (`PageRow.quoted` for another agent's) |
| A document of words | `MarkdownDocumentViewController` + `DocumentMarkdown` |
| Numbered monospaced lines | `NumberedLinesView` |
| A subagent's conversation | `TranscriptViewController` |
| The sidebar's party glyphs and coral | `.sidebarAgent`, `.sidebarSession`, `.sidebarWorkflow`, `.sidebarCoral` |
