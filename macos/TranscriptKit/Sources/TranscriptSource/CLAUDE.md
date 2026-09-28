# TranscriptSource

A read-only source editor, Xcode's: what a transcript's tools open into beside it — a file read, an edit's comparison, a command's output. **It depends on nothing**, not even `TranscriptKit`: a host hands it lines (`SourceDocument`) and it never learns what produced them.

| Type | Rule |
|---|---|
| `SourceDocument` / `SourceLine` | The one model for a file, a comparison and output: numbered lines, each `unchanged` / `added` / `removed` / `elided`, with word-level `changedRanges` and explicit `styles`. Build it here (`init(text:)`, `init(old:new:)`, `init(hunks:original:)`, `init(terminalOutput:)`), never by hand in a host. |
| `SyntaxHighlighter` / `SourceLanguage` | A one-pass lexer over a language **table**, not a grammar. It colours what Xcode colours without an index — keywords, literals, comments, attributes, directives, declared names, platform types. An unresolved name stays plain, as it does in Xcode for a file outside its project. |
| `ANSIText` | Output to lines: SGR kept as runs, every other escape dropped, a carriage-returned line kept as it finally read. |
| `SourceTheme` | Xcode's Default (Light)/(Dark). |
| `SourceView` | The view: `NSScrollView` + `SourceTextView` (TextKit 1) + `SourceGutterView`. |

## Look is Xcode's, measured

- **Syntax colours, faces and line spacing are copied from Xcode's own theme files** (`SourceEditor.framework/Resources/Default (Light|Dark).xccolortheme`): SF Mono 12, Regular with Semibold keywords in light, Medium with Bold in dark, `DVTLineSpacing` 1.1, doc comments proportional (HelveticaNeue / Helvetica) with the `///` marker kept in the code face. Change a value only by reading the theme again.
- **Comparison is Xcode's Inline Comparison** (Editor ▸ Code Review), sampled from the composited window: removed lines on `#FCF5F3` with **no number**, added on `#ECFBF0`, the changed words of a paired added line on `#D1F6DB` over the full line height; an added line with no removed partner is marked whole, a run of only additions nowhere; removals sit above additions in a run; a 3 pt striped blue bar at the gutter's leading edge beside each run, and the tint carried across the gutter. Dark tints are derived (same proportion of the system colours) — Xcode's dark comparison was not sampled.
- **Wrap Lines is on**, continuation lines hang four columns past the line's own indent, as Xcode's do.
- **Output colours are system colours**, not a terminal palette: black and white read as the label colour so nothing vanishes on either background.

## Mechanics

- **The gutter is a sibling view, not the scroll view's `NSRulerView`.** From macOS 26 a ruler floats over the clip view and the text under it never reached the screen (blank when composited; `cacheDisplay` drew it — the in-process redraw hides the bug). It redraws on the clip view's bounds notification and reads every position from the text view by conversion.
- **TextKit 1, non-contiguous layout:** the gutter and the tints ask for visible lines only (`lineIndexes(in:)`, `rect(ofLine:)`), so a long file lays out what is looked at.
- **Never set `textView.font` after filling the storage** — it replaces every face in the text with one.
- **Faces depend on appearance, colours don't:** colours are dynamic; `viewDidChangeEffectiveAppearance` restyles for the faces.
- Selection, Copy and the system find bar (⌘F, `usesFindBar`) are `NSTextView`'s; nothing is editable.
