# NativeTranscript2

A rewrite of the old `NativeTranscript`. Same approach (Core Text self-drawing on top of `NSTableView`), without the prior over-abstraction (component protocols, prepare cache, refinement passes, five reasons of update, ...).

## 0. The most important rule: **MVP = narrow scope, not low quality**

This is a *refactor*. It is **not** "write it sloppy now, polish later."

| Concept | Meaning |
|---|---|
| **Scope** | The MVP only ships heading + paragraph. User bubble / tool group / list / table are phased in later. |
| **Quality** | Every block kind, when it lands, matches the visual fidelity and behavior of the old code. There is no "ship a degraded MVP and improve it later" path. |

Concrete anti-patterns that have bitten us:

- ❌ "MVP doesn't need `.never` / responsive scrolling / negative-width clamp." **Wrong.** Those are the baseline chrome of any production `NSTableView`, not optimizations.
- ❌ "Use `pendingBlocks` for MVP, unify later." **Wrong.** The unified `currentBlocks + rebuild()` path costs the same; just write it correctly the first time.
- ❌ "Add a list with `NSParagraphStyle` for MVP, do sticky bullets later." **Wrong.** That's degraded quality. Either don't ship lists yet (scope), or ship them right (quality).

## 1. Architecture

```
SwiftUI: NativeTranscript2View (NSViewRepresentable)
   │
   ├─ makeCoordinator → Transcript2Coordinator (NSTableViewDataSource/Delegate)
   │
   └─ makeNSView →
      Transcript2ScrollView (NSScrollView, .never, responsive)
         └─ Transcript2ClipView (NSClipView, .never)
            └─ Transcript2TableView (NSTableView, negative-width clamp)
               └─ BlockCellView (NSView, override draw(_:), .onSetNeedsDisplay)
```

Data flow: `SwiftUI [Block] → updateNSView → Coordinator.setBlocks → rebuild → diff → NSTableView insertRows/removeRows/reloadRows`.

## 2. Invariants (violating any of these is a bug)

### 2.1 Rendering path

- Self-drawn cells use `override draw(_:)` with layer policy **`.onSetNeedsDisplay`** (not `.never`). `.never` is paired with `CALayerDelegate.draw`; this project doesn't take that route.
- `NSScrollView` and `NSClipView` use **`.never`** — they have no content of their own, just composite their children, so they contribute zero draw calls during scroll.
- `isCompatibleWithResponsiveScrolling = true`. Forgetting this drops you back to the synchronous `drawRect` slow path.

### 2.2 Data / layout / state

- **Stable ids drive the diff.** `Block.id: UUID` is caller-supplied. Never derive ids from content hashes — two consecutive identical messages would collapse into one.
- **Layout lifetime tracks `RowItem`.** `RowItem { id, block, layout: TextLayout }`. The layout is computed once and lives with the row. Do not introduce an external LRU cache (the old `TranscriptPrepareCache` was a patch around id instability; id-based reuse covers it now).
- **Row state** (fold flags, ...) lives in `Coordinator.foldStates: [UUID: Bool]`. **It does not go into `Block.Kind`** associated values. Two reasons:
  - State has to survive `.update` events on content (a content tweak must not undo the user's expand preference).
  - State has to survive `RowLayout` rebuilds (layout is a pure function of `(block, width, state)`; state is an *input*, not a stored field).

  Layouts therefore stay stateless. `userBubble` avoids in-cell expand via "hard truncate + sheet". `diff` reads `foldStates[id]` to drive collapsed↔expanded body shape; `Coordinator.toggleFold(id:)` flips the flag and, inside an animation group, calls `noteHeightOfRows` + `reloadData(forRowIndexes:)`. When you add a new stateful behavior: add a sparse-dict field on the coordinator (absent = default), and thread the value through `makeLayout` into the appropriate `XxxLayout.make` parameter.
- **Tool runtime status** is the second instance of the sparse-dict pattern: `Coordinator.statusStates: [UUID: ToolStatus]` (absent = `.completed`). The keyspace is shared with `foldStates` — top-level `Block.id` keys the group's status, `ToolGroupBlock.Child.id` keys a child's status. `Transcript2Controller.setToolStatus(id:status:)` → `Coordinator.setStatus(id:)` → `removeCachedLayout(for: hostBlockId)` + a single-row `reloadData(forRowIndexes:)`.

  **This deliberately does not go through `Change.update`**, because that route would needlessly drop highlight + drop selection and force the caller to rebuild `Block.Kind`. Status only changes header color / shimmer overlay (no height change), so `setStatus` also skips `noteHeightOfRows`.

  Status is folded into `ToolGroupLayout.Header.status` at `make` time; `drawHeader` and `subviewPlan` resolve color and shimmer through three helpers (`titleColor(for:hovered:)`, `chevronTint(for:hovered:)`, `wantsShimmer(for:)`). Adding a new status visual rule means editing only these helpers.

  **`.running` no longer uses a brighter hover-tier color** (that path produced a brightness pop on running↔completed transitions). Title and chevron colors are identical to `.completed`; the running affordance is a sweeping shimmer overlay (`SubviewPlan.Shimmer`).

  **Shimmer is an additive overlay, not a mask.** `drawHeader` always paints the base title in the secondary color into the cell bitmap (`wantsShimmer` no longer short-circuits). The overlay is a `CALayer` carrying a `labelColor` text bitmap with an `[α=0,1,0]` mask gradient — it adds `labelColor` pixels only where the stripe falls. This keeps base text fully opaque and sharp; a mask-based version dimmed the AA glyph edges and felt soft. The overlay layer frame is pixel-aligned in the cell reconciler using the host's backing scale; the bitmap is rendered via `CTLine` + `xOffset` to inject subpixel offset so overlay glyphs and cell-bitmap glyphs share the same subpixel position (no "double image" smear as the stripe sweeps). On hover, overlay opacity is forced to zero (the base already paints in `labelColor`, so adding more would be redundant). `viewDidChangeBackingProperties` propagates `contentsScale` to every sublayer and invalidates cached glyph bitmaps, so dragging across displays doesn't leave stale rasterizations.

  **`SubviewPlan.Chevron` carries a resolved `strokeColor` + `alpha`** (status + hover already folded in). **`SubviewPlan.Shimmer` carries `textRect` + title + font + hovered**; highlight color, sweep speed, gradient locations, and pixel alignment all live inside the cell reconciler. The cell stays state-enum-free.

- **`currentBlocks + rebuild()` is the only path.** `setBlocks` and `frameDidChange` both call `rebuild()`. `rebuild` early-exits on `width <= 0`. **Do not reintroduce a `pendingBlocks` side-channel.**

### 2.3 Diff path

- Granular `insertRows` / `removeRows` / `reloadRows` + `noteHeightOfRows`, never `reloadData()`.
- `Swift.CollectionDifference` computes structural diff; same-id, content-changed rows go into an additional `contentChanged` `IndexSet`.
- Wrap mutations in `tableView.beginUpdates` / `endUpdates`. Do not re-enter the data source between them.

## 3. Layout boundaries (what `XxxLayout` owns)

> **`XxxLayout`** is an immutable value that captures the width-dependent geometry needed to (a) report a row's height to `NSTableView` and (b) draw the block's main body, derived from a particular block payload, the current width, and (optionally) coordinator-held state.

To decide whether a piece of code belongs in a `Layout`, all three must be true:

1. **Is it a pure function of width?** (Deterministic input → output, no hover/selection/animation awareness.)
2. **Is it row-body content?** (Would changing it change row height? If yes → Layout. If no → cell decoration.)
3. **Must it be computed before `draw`?** (`heightOfRow` has to return synchronously — no ad-hoc layout at draw time.)

All three yes → `Layout`. **State is an input to the layout function, not a stored field** (`make(input, width, state) -> Layout`).

### Layout vs. CellView

| Layout owns | CellView owns |
|---|---|
| Glyph positions / image rects / table-cell content | Row padding, corner radius, shadows, loading placeholders |
| Anything that **changes row height** | Anything purely decorative (does not affect height) |
| A description of subviews / sublayers the cell needs to host (`SubviewPlan`) | Reconciling subviews / sublayers against the current plan |

### Dispatching across layouts

`enum RowLayout` wraps each concrete `XxxLayout` and exposes a uniform `totalHeight` / `measuredWidth` / `draw(in:origin:)`. The cell never inspects the enum — it just calls `layout.draw`.

Adding a new layout kind = one new `RowLayout` case + one line in each of the three switches.

### Cells aren't 100% self-drawn — the AppKit adapter pattern

`BlockCellView` mostly uses `override draw(_:)`, but **not** as a single bitmap. Some animations and interactions can't be expressed in `CGContext` and need real AppKit decorations:

| Decoration | Type | Why not self-draw |
|---|---|---|
| Chevron rotation | `CAShapeLayer` sublayer | `transform.rotation.z` + `CABasicAnimation` is one line; self-drawing would mean redrawing every frame. |
| Slidable inline body | `NSView` subview (layer-backed) | Multiple body slabs on one row need to slide past each other during fold transitions. Only `view.animator().frame` can express that; a single bitmap can only crossfade. |

**How a layout declares decorations:** `RowLayout` exposes `subviewPlan(origin:hoveredAction:selection:) -> SubviewPlan`. Layouts that need none return an empty plan; only the ones that need decorations (today: `toolGroup`) return non-empty. `SubviewPlan` is a **struct + closures** — same shape as `SelectionAdapter`, never a protocol. The cell doesn't know which layout produced the plan; it just runs the generic reconciler.

**Don't introduce a protocol for "which layout needs decorations".** Same rationale as `ToolGroupChildLayout`: protocols make "forgot to implement it on this case" possible. Enum cases force the compiler to check.

**Extending `SubviewPlan`:**
- Adding a new decoration category (today: chevron / entry / shimmer) → add a field on `SubviewPlan` + a reconcile arm in `BlockCellView+SubviewPlan.swift`.
- Letting another layout emit decorations → add an arm in `RowLayout.subviewPlan` and implement `subviewPlan(...)` in that layout's own file.

## 4. Adding a new block kind

Add a `case` to `enum Block.Kind`. Then:

1. **Decide whether you need a new `Layout` type** (re-run the three checks in §3).
2. **Add a `Transcript2Coordinator.makeRowItem` arm**: dispatch to the matching `XxxLayout.make`, wrap in the matching `RowLayout` case.
3. **If it's a new layout type**: add `Layout/XxxLayout.swift` and a case to the `RowLayout` enum.
4. **Do not bring back `BlockStyle.attributed(for: Block)`** (deleted). That "all blocks → one attributed string" shape doesn't survive non-text blocks. Dispatch per kind in `makeRowItem`.

### Implemented examples

- `case .heading(level: Int, inlines: [InlineNode])` / `case .paragraph(inlines: [InlineNode])` → `TextLayout`, via `BlockStyle.headingAttributed(level:inlines:)` / `paragraphAttributed(inlines:)`, which folds inline IR into an `NSAttributedString`. There is **no** `String` overload — callers without a parser wrap manually as `[.text(s)]`.
- `InlineNode` is the recursive inline IR (text / strong / emphasis / code / link / lineBreak), produced by the upstream Markdown parser. The block layer holds it but does not parse it.
- `case .image(NSImage)` → `ImageLayout` (aspect-fit with a `maxHeight` fallback).
- `case .toolGroup(ToolGroupBlock)` → `ToolGroupLayout`. One row hosts the entire tool group; the appearance must remain pixel-identical to the old `NativeTranscript.GroupComponent` — font sizes, colors, chevron shape, hover behavior, padding. Don't drift.

  **Visuals (1:1 with old `GroupComponent`):**
  - **Group header** (24pt) sits at the top of the row: title plus a chevron on the right. Title is 12pt medium `secondaryLabel`; chevron is 8pt; title↔chevron gap is 6pt. No icon. No inset (layout-local `x=0`; the row's horizontal padding comes from `layoutOrigin.x` on the cell).
  - **Child headers** use the exact same constants (`BlockStyle.toolHeader*`). Spacing between consecutive child headers, and between the group header and the first child header, is `toolHeaderChildSpacing = 4pt`.
  - **Chevron path** — two self-drawn line segments forming `>` (`lineWidth = 1.4`, round caps/joins). Do not swap in an SF Symbol; the old `CGShapeLayer` used the same path. Idle alpha = 0.35, hover alpha = 0.85. Folded → `rotation = 0` (pointing right); expanded → `rotation = π/2` (pointing down).
  - **Chevron visual-center compensation** — `visualCompensation = max(0, (font.capHeight - font.xHeight) / 2)`. The chevron's `centre.y` adds this offset on top of `midY` so it aligns with the title's x-height midline (without it the chevron drifts visually above the title).
  - **Hover highlight** — `BlockCellView` tracks hit via `NSTrackingArea` (`.mouseMoved` + `.mouseEnteredAndExited` + `.activeInKeyWindow` + `.inVisibleRect`) and passes the resolved `HitAction` to `RowLayout.draw(in:origin:hoveredAction:)`. `ToolGroupLayout.draw` matches `.toggleFold(id)` against each header's `foldId`; matching headers swap title to `.labelColor` and chevron alpha to the hover value. Other layouts ignore `hoveredAction`.
  - **Expanded body** — under an opened child header, a 4pt gap, then a `codeBlock`-style rounded rect (fill = `diffContainerBackground`, corner = `structuralCornerRadius`). `ToolGroupChildLayout` dispatches to the per-kind layout file (today the only one with a body is `FileEditChildLayout`, which calls `DiffLayout` for hunks).

  **Fold-state routing:** the `UUID` in `HitAction.toggleFold(UUID)` can be either the group host's `Block.id` (group header) or a `Child.id` (child header). `Coordinator.toggleFold(id:)` **must** search both `blocks.firstIndex(where: { $0.id == id })` and `children.contains(where: { $0.id == id })` across every tool group to locate the host row. Searching only top-level blocks would leave child-header clicks dead.

  **Three-state labels (group + child):** `ToolGroupBlock` holds three titles (`activeTitle` / `expandedActiveTitle` / `completedTitle`). `group.resolvedTitle(status:isExpanded:)` is the single source of truth:
  - `.running` + folded → `activeTitle` (the in-progress final child)
  - `.running` + expanded → `expandedActiveTitle` (aggregate progressive form)
  - any terminal state (`.completed` / `.failed` / `.cancelled`) → `completedTitle` (aggregate past form)

  Children mirror this: each payload exposes `label` (past form) and `activeLabel` (progressive form), with `Child.headerLabel(for: ToolStatus)` choosing — `.running` → `activeLabel`, otherwise → `label`. The bridge (`MessageEntryBlockBuilder` + `ToolUseToChild`) populates **both** labels; the layout switches in place using `statusStates[id]`. **This does not go through `Change.update`** to rebuild `Block.Kind`. The source of the three titles is `SessionHandle2.GroupEntry.activeTitle` / `expandedActiveTitle` / `completedTitle` (corresponding to `activeCountPhrase` / `completedCountPhrase`). For a single-tool group, use `ToolUse.activeFragment` / `completedFragment` directly — do not route through `activeCountPhrase(1)`, which would blur "Reading foo.swift" into "Reading 1 file".

  **Adding a new child kind:**
  1. Create `Layout/ToolGroupChildren/<Kind>/<Kind>Child.swift` with the payload struct (must expose `id` / `label` / `activeLabel`; `id` drives fold state and highlight scope, `label` is the past form, `activeLabel` is the progressive form; `Child.headerLabel(for: ToolStatus)` selects). In `Block.swift`, add the enum case and one arm to each of the `id` / `label` / `activeLabel` / `hasExpandableBody` switches.
  2. Create `Layout/ToolGroupChildren/<Kind>/<Kind>ChildLayout.swift` implementing `make / totalHeight / draw / drawBackplate`. For multi-sub-card bodies, reuse `TextCardSection.build / drawBackplates / draw` rather than reimplementing sub-card geometry.
  3. Add the case to `ToolGroupChildLayout` plus four switch arms (`totalHeight`, `drawBackplate`, `draw`, `make`).
  4. **Header-only kinds** (`.read` / `.generic`): `hasExpandableBody = false`, layout `totalHeight == 0`, empty `draw` and `drawBackplate`. `ToolGroupLayout` skips chevron drawing and skips registering the fold hit automatically.
  5. If async highlighting is needed, add a case to `ToolGroupChildHighlight.requests(for:)` that returns a `Plan`.
  6. If the body should be selectable (`selectionAdapter`):
     - Bodies built on `TextCardSection` (bash / grep / glob / webFetch / webSearch / askUserQuestion / agent) are zero-effort — `ToolGroupChildLayout.textCardSections` already exposes the section list, and `ToolGroupLayout.selectionAdapter.buildRegions` produces one `LayoutPosition.textCard(childIndex:sectionIndex:char:)` region per section. You only need to extend `LayoutPosition` if your new kind **isn't** built on `TextCardSection`: add a concrete case and route it through a `buildRegions` arm.
     - Selection granularity is section-local (drags that cross sections clamp to the start section). Cross-child drags clamp the same way. `fileEdit` is the lone exception: it uses `LayoutPosition.diff(childIndex:char:)` because `DiffLayout` strips its own gutter and sign columns and can't share `TextLayout`'s path.

  **Implemented child kinds** (each in its own `Layout/ToolGroupChildren/<Kind>/` subdirectory):

  | Kind | Body |
  |---|---|
  | `read` / `generic` | Header-only (no chevron) |
  | `fileEdit` | Diff card (`DiffLayout` + per-line highlight) |
  | `bash` | Command / stdout / stderr — three monospaced sub-cards; stderr in red |
  | `grep` | Filenames + optional content preview, two sub-cards |
  | `glob` | Filenames + optional "… truncated" tail, single card |
  | `webFetch` | Response body, single card (plain text) |
  | `webSearch` | Results list (title semibold / url monospace / snippet) |
  | `askUserQuestion` | Q&A list (semibold question + answer / "awaiting answer…") |
  | `agent` | Progress card (`↳ ` prefix) + output card |

  **No protocols.** Enum dispatch gives exhaustiveness checking; a protocol would let you forget an implementation in some file.

  **Child header text uses the payload's own `label`, not the raw file path.** `FileEditChild` carries both `label` (display, e.g. "Edit Sources/Greeter.swift", past form) and `filePath` (for language detection in highlighting). This matches the old `ReadChildRenderer`'s `tool.completedFragment` convention — when a group is expanded, children always show their completed form, and the running affordance is reflected on the group title instead.

  **Async highlighting:** scope = `Transcript2HighlightScope.toolGroupChild(itemId: child.id)`. Each child decides the `HighlightValue` shape. `fileEdit` uses per-unique-line `.lineMap` (same as the old `NativeDiffView`); the key is the raw line content. Line metrics don't depend on tokens, so `onDidFill` is a `reloadData(forRowIndexes:)` only — no `noteHeightOfRows`.

  **New-file mode (`oldString == nil`):** `.add` lines render as `.context` (no `+` sign, no add background); gutter line numbers + token highlight are preserved. The output reads as a "line-numbered code view," not a "diff with everything added."

  **Selection is supported on every visible body.** `fileEdit` uses `LayoutPosition.diff(childIndex:char:)`; the other seven kinds (bash / grep / glob / webFetch / webSearch / askUserQuestion / agent) use `LayoutPosition.textCard(childIndex:sectionIndex:char:)` with per-card granularity. `read` / `generic` are header-only and have nothing to select.

- `case .userBubble(text: String)` → `UserBubbleLayout`. Right-aligned bubble; long text hard-truncates at `userBubbleCollapseThreshold` lines, the last line trims with `CTLineCreateTruncatedLine` + an ellipsis, and a `>` chevron sits inside the padding. Selection clamps to the prefix lines — the truncated tail is not selectable. **The layout is fully stateless** and has no fold flag. Chevron `mouseDown` → `Coordinator.requestUserBubbleSheet(id:)` → routes through the `onUserBubbleSheetRequested` closure to `Transcript2Controller.pendingUserBubbleSheet` (`@Observable`) → SwiftUI's `.sheet(item:)` shows the full content (`Text.textSelection(.enabled)` for copy). This is the **only** legal SwiftUI escape hatch from the NSView loop: `.sheet(item:)` is a presentation primitive that must be owned by SwiftUI, but in-cell rendering, hit testing, and selection stay entirely inside NSView.

## 5. File layout

```
NativeTranscript2/
├── Model/
│   └── Block.swift                  Block data + font/inset constants + bubble / chevron / code / diff geometry constants
├── Layout/
│   ├── TextLayout.swift             Core Text layout result (immutable + draw)
│   ├── ImageLayout.swift            Aspect-fit + draw (NSImage carries the bitmap)
│   ├── ListLayout.swift             Recursive list with self-drawn markers / checkboxes
│   ├── TableLayout.swift            CSS-like min/max column allocation + self-drawn grid
│   ├── UserBubbleLayout.swift       Right-aligned bubble + chevron + fade mask + selection clamp
│   ├── CodeBlockLayout.swift        Header (lang + copy) + embedded TextLayout body + async token coloring
│   ├── BlockquoteLayout.swift       Left bar + embedded TextLayout
│   ├── ThematicBreakLayout.swift    Single hairline
│   ├── ToolGroupLayout.swift        Tool group row (group header + child headers + expanded body); dispatches into ToolGroupChildLayout
│   ├── ToolGroupChildren/           Per-kind tool-group child layouts (payload + layout colocated)
│   │   ├── ToolGroupChildLayout.swift     Enum dispatch for totalHeight / draw / drawBackplate + `make` factory
│   │   ├── ToolGroupChildHighlight.swift  Per-kind highlight requests + finalize
│   │   ├── TextCardSection.swift          Shared geometry + draw helpers for multi-card sub-bodies
│   │   ├── FileEdit/                      Diff body (header + body)
│   │   │   ├── FileEditChild.swift            Payload struct
│   │   │   ├── FileEditChildLayout.swift      Thin wrapper that calls DiffLayout
│   │   │   ├── FileEditChildHighlight.swift   Per-unique-line highlight requests + finalize
│   │   │   ├── DiffBlock.swift                Diff payload (old/new + derived hunks)
│   │   │   └── DiffLayout.swift               Hunks body (`codeBlock`-style rounded rect with per-line gutter / sign / content)
│   │   ├── Read/                          Header-only: ReadChild + ReadChildLayout (totalHeight = 0)
│   │   ├── Generic/                       Header-only fallback: GenericChild + GenericChildLayout (totalHeight = 0)
│   │   ├── Bash/                          Command + stdout + stderr, three sub-cards
│   │   ├── Grep/                          Filenames + content preview, two sub-cards
│   │   ├── Glob/                          Filenames + optional "… truncated" tail, single card
│   │   ├── WebFetch/                      Response body, single card (plain text)
│   │   ├── WebSearch/                     Results list, single card (title / url / snippet)
│   │   ├── AskUserQuestion/               Q&A list, single card
│   │   └── Agent/                         Progress + output, two sub-cards
│   ├── SelectionAdapter.swift       Selection-facing API (per-layout, struct + closures)
│   ├── SubviewPlan.swift            Chevron + entry-subview decoration plan (per-layout, same shape as SelectionAdapter)
│   └── RowLayout.swift              Enum dispatch (text / image / list / table / userBubble / codeBlock / blockquote / thematicBreak / toolGroup)
├── AppKit/
│   ├── Transcript2ScrollView.swift  NSScrollView + NSClipView subclasses
│   ├── Transcript2TableView.swift   NSTableView subclass (negative-width clamp)
│   ├── CenteredRowView.swift        Row-view placeholder subclass (no-op body); exists so NSTableView.makeView has a stable row-reuse key
│   ├── BlockCellView.swift          Self-drawn cell: layoutOrigin.x = cellOriginX + blockHorizontalPadding for centering + layout.draw + link/chevron hit testing + selection + hover tracking
│   └── BlockCellView+SubviewPlan.swift  Reconciles the chevron sublayer and entry subview against the layout's SubviewPlan; ToolGroupEntryView also lives here
├── Transcript2Coordinator.swift          DataSource/Delegate + diff + per-kind dispatch + chevron sheet request routing
├── Transcript2Controller.swift           Imperative command channel (apply / loadInitial)
├── Transcript2SelectionCoordinator.swift Cross-row selection algorithm (reads layout.selectionAdapter)
└── NativeTranscript2View.swift      SwiftUI bridge (updateNSView is a no-op) + Preview
```

Dependencies only flow downward: `NativeTranscript2View → Coordinator → AppKit/ → Layout/ → Model/`.

## 6. Async highlight back-fill

`Transcript2HighlightStorage` is a per-block async side-channel. The framework already supports two value shapes:

| Scope | Value | Used by |
|---|---|---|
| `.codeBlock` | `.tokens([SyntaxToken])` | Whole-block code highlighting |
| `.diff` | `.lineMap([content: tokens])` | Per-unique-line highlight in diffs; key is the raw line content |

**Back-fill flow** (the same for every highlight-bearing kind):

1. `Coordinator.apply` calls `storage.schedule(block)` on `.insert` / `.update`.
2. `schedule` dispatches via `plan(for: block)`, which returns a `Plan { payload, writeback }`.
3. A single `engine.highlightBatch(payload)` crosses into JSCore; results are written back through `writeback`.
4. `onDidFill(blockId)` triggers `removeCachedLayout(for: id)` + `reloadData(forRowIndexes:)`.
5. The next `viewFor` call's `makeLayout` reads the storage snapshot and produces a colored layout.

**Generation guard:** both `schedule` and `drop` bump `inflightGen[blockId]`. When a job finishes it compares generations; on drift it discards the result. This prevents an old highlight from overwriting newer content (e.g. after `.update` replaces `oldCode` with `newCode`, the in-flight job from the old version must not write back).

**Layout invariant:** highlight back-fill only changes colors, not metrics — under the same font and width, glyph positions don't shift based on token presence. That's why `onDidFill` only does `reloadData(forRowIndexes:)` and not `noteHeightOfRows`: the latter would re-layout every following row for no visual reason.

**Adding a new highlight-bearing kind:**

1. Add a case to `Transcript2HighlightScope` (if `.tokens` / `.lineMap` aren't reusable, extend `HighlightValue` with a new shape).
2. Add a `Storage.plan(for:)` arm that returns the `payload` + `writeback` for the new kind.
3. Make `XxxLayout.make` accept the matching optional (e.g. `tokens: [SyntaxToken]?` or `lineMap: [String: [SyntaxToken]]?`).
4. Add an arm to `Coordinator.makeLayout` that pulls the value from the `highlights` snapshot, pattern-matches the token shape, and threads it through.

The framework itself doesn't change — storage and the reload pipeline are generic.

## 7. Pre-flight checklist before changes

- Touching `Coordinator` diff / pipeline: run the SwiftUI Preview (`NativeTranscript2View.swift` `#Preview`) and eyeball insert/remove animations.
- Touching `BlockCellView.draw`: Preview to verify layout + font.
- Touching `TextLayout.make`: Preview is enough; the function is pure and hard to break in subtle ways.
- Touching `Transcript2ScrollView` / `Transcript2TableView`: run the app (`make build` + launch) and drag the window width to verify reflow.
