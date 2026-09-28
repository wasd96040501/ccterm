# TranscriptKitDemo

`make demo-kit` from the repo root (`swift run TranscriptKitDemo`); it runs in the foreground and quits when its one window closes. The demo is for what **tests can't assert** — whether a document *looks* like a document, whether motion reads right. Anything assertable belongs in `TranscriptKitTests` instead.

## Shape

- The window is a `TranscriptWorkspace` editor area: each tab is one transcript with its own host (`DemoHost`), find bar and stream; ⌃⌘T opens a second editor. Every tool acts on the **active** editor's selected tab.
- **The tool palette is built like an AppKit toolbar — copy this, don't re-derive it:** its buttons are **nil-targeted actions with the same selectors as the menu items**, so a tool and its menu item are one command; they're enabled by the window controller's single `validateUserInterfaceItem(_:)`, asked on every window update; a command carrying a value is sent with the palette as sender and reads the value off it (as `changeColor(_:)` reads `NSColorPanel`). Folding (the round toggle or ⌥⌘T) hides an arranged view in an animation group, both glass pieces in one `NSGlassEffectContainerView`.
- **`FindBarView`** is the demo's, over each tab's transcript — a view + delegate: it reports the query and `NSTextFinder.Action`s, is told the count, and knows nothing about what it searches. No Aa / Contains / replace controls — `TranscriptView.find(_:)` takes no options, and controls that do nothing are worse than none. Return / ⇧Return step; Escape / Done hide; the count reads "No matches" / "1 match" / "N matches"; arrows enable only when there's somewhere to go. Its `NSTextFieldDelegate` is a private helper, so being one is not the bar's surface; `FindBarViewTests` reaches it through the test target's dependency on the demo.
- The demo deliberately **doesn't implement** `transcriptView(_:menu:forRow:)` (it shows what a host gets by default — Copy) or `didActivateMoreInRow:`. Their behaviour is covered by tests.

## Coverage rules

- **`DemoMessage.script` uses every node in `MarkdownIR`** — all heading levels, every list shape (ordered with start index, task, nested, tight and loose), fenced / indented / info-string code, a table with all four alignments and a spanned cell, nested blockquotes holding blocks, thematic breaks, footnotes in all four states, images with alt / title / neither, one paragraph containing every inline node. **A shape missing from the script is a shape nobody looks at** — landing a new node means adding it here.
- `referencesAndNotes` puts things that should *not* change side by side (`--amend` stays `--amend`, `socket.io` stays plain) — a regression there reads as ordinary text.
- **Picture rows** (`DemoImage`, labelled with index and proportion) walk `MosaicLayout`'s branches in the order the algorithm reaches them; a mis-packed group is obvious on screen and invisible in a number.
- **User messages** are drawn by the package (`.userMessage`), so no text row in the demo is a host row. Eyeball: a short message reads as a pill, the gutter reads as one side of a conversation, the fill is a tint. One message is long enough to show **More**.
- **Streaming is on the palette because none of it is assertable:** type a row number and press Stream, then select text in that row and watch it survive; scroll up and watch the viewport hold; scroll back down and watch the tail re-engage.
- **Hover / press:** the band and its 8% → 16% press step are drawn by the package; `LinkTooltip` is one host's label.
- The **mutation** buttons and **Cold Load** / **Content Width** sections are how scroll anchoring, prepared loads and resize remeasure get checked by eye; keep them working through any rendering change.
