# ExactList — behavioural specification

This document is **normative**. Every requirement has an ID (`G3`, `A5`, …).
Every ID has at least one test whose name contains it, and a test in the
package checks that (§13). Changing any behaviour means changing this document
first; see §14.

The reference point is AppKit's view-based `NSTableView`. Where this list
behaves the same, it uses AppKit's spelling and says so. Where it behaves
differently, the reason is written down here and in the member's doc comment.

---

## 1. The problem

A vertical list shows `n` rows, top to bottom, in a scrolling viewport:

- each row is a host `NSView`;
- each row has an exact height, and that height depends on the width it is
  laid out at;
- the host changes the list over time: it inserts, removes and moves rows,
  changes their height, and reloads their contents;
- the list's width changes too: the window is resized, a split divider moves,
  a sidebar animates open.

The list guarantees four things through all of this:

1. **Exact geometry.** Every row's position comes from heights the delegate
   actually returned. Nothing is sampled or extrapolated.
2. **Where the reader is looking stays put**, and the rule that decides this is
   stated here and can be controlled per update.
3. **Changes move on screen with CoreAnimation**, and the moving rows stay in
   lockstep with the scroll position. The scroll position is never corrected
   after the fact.
4. **The order of setup cannot be wrong.** It is either impossible to express,
   or harmless when it happens.

`NSTableView` guarantees none of these (§2).

---

## 2. Where this goes beyond `NSTableView`

Each row names what `NSTableView` does, how that was established, what this
list guarantees instead, and the requirement that proves it. "Characterized"
means a test in this package runs `NSTableView` and asserts that behaviour
(`NSTableViewCharacterizationTests`), so the claim stays true on the OS the
suite runs on.

| Aspect | `NSTableView` | ExactList | Proof |
|---|---|---|---|
| Geometry | Asks the delegate for a few hundred rows' heights and extrapolates the rest. The scroll range is wrong until the reader reaches the end. *Characterized.* | Every row's height comes from the delegate before that row enters the document. Row positions are prefix sums of those heights. | G1–G5 |
| Scroll position across changes | Not specified. `insertRows` only promises that `numberOfRows` grows (docs). A change above the viewport moves the content. *Characterized.* | Anchoring rules, stated in §6, keep a named row at its screen position through every change, including width and viewport changes. | A1–A9, V1–V5 |
| Animation vs. scroll position | No API changes the scroll offset as part of an animated update. A host's compensation is a separate write, final while the rows are still sliding (docs: none of the update methods takes an offset). | One commit sets geometry and offset to their final values. The motion is additive CoreAnimation animations whose start values exactly cancel the jump. The anchor row never moves on any frame. | M1–M10 |
| Interrupting an animation | A new update starts from the model values, so the rows jump. | Additive animations compose: a new update in the middle of an animation keeps every row's presented position continuous. | M8 |
| Choosing the behaviour | No per-update control of where the viewport stays. | Every batch takes an `Anchoring` value (`.automatic`, `.row(i)`, `.scrollOffset`). Animation duration and curve come from `NSAnimationContext`, and Reduce Motion is honoured. | A2, M1, M9 |
| Setup order | The data source is settable at any time. The first load happens when the table first tiles, so loading before layout measures rows at the wrong width. *Characterized.* | The data source and delegate are injected in `init` and cannot be replaced. Loading happens by itself at the first layout that has a real width. No delegate call ever sees a width of zero or less. | L1–L8 |
| When an update takes effect | Some effects wait for the next layout pass. | Every update is committed before the call returns. `rect(ofRow:)` is final immediately afterwards. | U1 |
| Width changes | The host has to call `noteHeightOfRows`. Rows can be shown at a stale height until it does. | The list re-measures every row in the prepared area in the same layout pass that changes the width. No row is ever displayed at a height measured for a different width. | W1–W6 |
| Blank areas | Row views can end up where the geometry doesn't say they are. | After every commit, the mounted views are exactly the rows the geometry puts in the prepared area, at exactly their computed frames. On every animation frame, the rows cover the viewport. | P1–P4, M6 |
| Accessibility | Table role with row elements. | The same roles and attributes, for every row, mounted or not. | X1–X5 |
| Performance | — | For the same workloads in the same `-O` build, scrolling and updates are no slower than `NSTableView`. Loading is gated separately, because exactness asks for every row's height. | B1–B4 |

---

## 3. Terms

AppKit's words are used wherever AppKit has one.

| Term | Meaning |
|---|---|
| **row** | An index `0..<n`. It has no identity beyond its index, the same as in `NSTableView`. |
| **content width** `W` | The width every row is laid out at. It equals the clip view's width. |
| **height** `h(i)` | What `listView(_:heightOfRow:width:)` returned for row `i` at some width. It is finite and greater than 0. |
| **row spacing** `s` | The gap between two adjacent rows (`rowSpacing`, named after `NSGridView.rowSpacing`). |
| **document** | The flipped coordinate space the rows are laid out in. `y` grows downward and row 0's top is at `y = 0`. |
| **offset** `o` | The clip view's `bounds.origin.y`, in document coordinates. |
| **viewport height** `V` | The clip view's height. |
| **content insets** `t`, `b` | The top and bottom `contentInsets` (`NSScrollView.contentInsets`). |
| **unobscured viewport** `U` | The document interval `[o + t, o + V − b]`, which is what the reader can see. |
| **tail** | The end of the scrollable range: `o ≥ oMax − ε`, with `ε = 1` pt. |
| **overscan** `q` | `(V − t − b) / 2`: how far beyond `U` rows are kept ready, on each side. |
| **prepared area** `P` | `[o + t − q, o + V − b + q]`, named after `NSView.preparedContentRect`. |
| **mounted** | A row whose view is in the document right now. |
| **batch** | A group of updates announced together. One call outside a batch is a batch of one. |
| **commit** | Applying a batch: the new geometry, the new offset, and the mounted set all change in one step (§7). |
| **anchor** | What a commit holds still on screen (§6). |
| **stale** | A row whose height was measured at a width other than the current `W` (§9). |
| **load point** | The first layout pass in which the list is in a window and `W > 0` (§4). |

---

## 4. Lifecycle and mount order

The goal is that setup mistakes cannot be written, and where they can be
written they do nothing.

- **L1: injected, not assigned.** `ExactListView.init(dataSource:delegate:)` is
  the only initializer. It holds both weakly (the AppKit ownership), and
  neither can be replaced afterwards: there is no setter. A list with no data
  source, or one whose data source changes halfway through, cannot be written.
  *Deviation from `NSTableView`'s settable `dataSource`/`delegate`:* a settable
  pair is what makes "assigned after mounting" and "forgot `reloadData()`"
  possible at all.
- **L2: the list owns its scroll view.** `ExactListView` is the only view the
  host mounts, and it contains its own `NSScrollView`, clip view and document
  view. None of the three is public, so the list cannot be placed in the wrong
  container, and its document view cannot be replaced.
  *Deviation:* `NSTableView` is a document view that the host wraps in a scroll
  view, and the scroll view's configuration is then the host's to get right.
- **L3: nothing is asked before the load point.** Until the first `layout()` in
  which `window != nil` and `W > 0`, the list makes no data source or delegate
  call of any kind.
- **L4: loading is automatic.** At the load point, the list asks
  `numberOfRows(in:)`, then asks for every row's height at `W`, in ascending
  order, then asks for views for the rows that intersect `P`. No `reloadData()`
  is needed for the first load.
- **L5: calls before the load point are harmless and defined.**
  - Updates (inserts, removals, moves, reloads, height notes, and
    `reloadData()`) are ignored. The load reads the data source as it is then.
    A batch's completion handler still runs, with `true`, on a later turn
    (U8).
  - `numberOfRows` returns 0, `rect(ofRow:)` returns `.zero`, `row(at:)`
    returns −1, `view(atRow:)` returns `nil`, and `rows(in:)` returns an empty
    range.
  - A scroll request (`scrollRowToVisible`, `scrollToRow(_:at:)`) is recorded.
    The last one wins, and it is applied at the load point without animation.
- **L6: the initial position** at the load point is, in order of precedence:
  the recorded scroll request; the tail, if `automaticallyFollowsTail` is on;
  otherwise the top (`o = oMin`).
- **L7: never measure at a width that won't be shown.** Every `heightOfRow`
  call receives the `W` the list is displaying, or is about to display in the
  same layout pass, and never a width ≤ 0. If `W` drops to 0 after loading
  (a collapsed split pane, for example), the list makes no calls and keeps its
  geometry. When `W` becomes positive again, that is a width change (§9).
- **L8: leaving the window changes nothing.** Removing the list from a window
  and adding it back makes no calls and keeps every row's height, the offset
  and the mounted views. A different `W` on the way back in is a width change.
- **L9: re-entrancy is a programmer error.** These stop with a precondition
  failure; `NSTableView` raises in the same situations.
  - Calling any update, `reloadData()` or scroll method from inside a data
    source or delegate callback.
  - Calling a single-call update (U4), `reloadData()`, a scroll method or a
    geometry query on the list from inside a batch closure. The closure's
    `Updates` proxy is the only way in.

  One exception: a `performBatchUpdates` call nested inside a batch closure is
  allowed, and it flattens into the outermost batch (U3).
- **L10: the count is checked.** When a batch commits, `numberOfRows(in:)` must
  equal the previous count plus inserts minus removals. Otherwise the list
  stops with a precondition failure, the same condition `NSTableView` raises
  `NSInternalInconsistencyException` for.
- **L11: the internal scroll view is configured one way, and it is fixed.**
  - `hasVerticalScroller = true` and `hasHorizontalScroller = false`.
  - `drawsBackground = false`, and the clip view draws none either. The host
    owns the background.
  - `automaticallyAdjustsContentInsets = false`. Otherwise AppKit rewrites the
    insets on every tile, which would undo `contentInsets`.
  - `borderType = .noBorder`.
  - The scroller style follows the system setting.
  - The vertical elasticity is `NSScrollView`'s default.

  The host's knobs are `contentInsets`, `rowSpacing` and
  `automaticallyFollowsTail` (§6.4), and nothing else.
- **L12: invalid input is a programmer error.** These stop with a precondition
  failure:
  - `heightOfRow` returns a value that is not finite, or is ≤ 0;
  - `rowSpacing` is set to a value that is not finite, or is < 0;
  - an index is out of range, whether in an update, in `.row(r)`, or in a
    scroll request;
  - the data source or the delegate has been deallocated when the list needs
    it (at the load point, at a commit, or during placement).

---

## 5. Geometry

- **G1: prefix sums.** `y(0) = 0`, and `y(i) = Σ_{k<i} h(k) + i·s`. Row `i`'s
  frame in document coordinates is `(0, y(i), W, h(i))`.
- **G2: exact content height.** `H = Σ h + (n − 1)·s` when `n ≥ 1`, and `0`
  when `n = 0`. The document's height is `H`. Nothing is estimated.
- **G3: the scroll range.** `oMin = −t`, and `oMax = max(oMin, H − V + b)`.
  Every offset the list sets lies in `[oMin, oMax]`.
- **G4: queries.** All geometry queries are in `ExactListView`'s own
  coordinate space. That space is flipped, so it can be converted with
  `convert(_:to:)` directly.
  - `rect(ofRow:)` returns the frame from G1, shifted by the current offset.
    Out of range, it returns `.zero`, as `NSTableView` does.
  - `row(at:)` returns the row whose frame contains the point, or −1. A point
    in a spacing gap belongs to no row.
  - `rows(in:)` returns the rows whose frames intersect the rect, as a
    `Range<Int>`. `NSTableView` returns an `NSRange`, which Swift callers
    convert straight back.

  *Deviation from `NSTableView`:* its answers are in document coordinates, and
  here the document view is not public (L2).
- **G5: cost.**
  - Mapping an index to `y`, and `y` to an index: O(log n).
  - A height change: O(log n) per row.
  - Each structural call inside a batch (insert, remove, move): O(n).
  - Applying a batch at commit: O(n).
- **G6: tolerance.** Floating-point sums may differ from a naive left-to-right
  sum by at most `1e-6 · max(1, H)` pt. Tests compare with that tolerance and
  no looser.

---

## 6. Anchoring

The anchor is resolved **before** a batch's changes, carried through them, and
restored **after**, all inside the same commit.

### 6.1 The policy

```swift
public enum Anchoring { case automatic, row(Int), scrollOffset }
```

- **A1: `.automatic`**, the default:
  - If `automaticallyFollowsTail` is on and the viewport is at the tail, the
    anchor is **tail**.
  - Otherwise, if `n > 0`, it is the **first visible row**: the smallest `a`
    with `y(a) + h(a) > o + t`. The anchor is `(a, d)`, where
    `d = y(a) − (o + t)`, which is `≤ 0` when the row starts above the
    viewport.
  - Otherwise (no rows, or no row reaches `o + t`), the anchor is the
    offset `o`.
- **A2: `.row(r)`** anchors row `r` (a pre-batch index) at `d = y(r) − (o + t)`,
  whether `r` is visible or not. This is how a host says which row the reader
  acted on. The intended use is a reader expanding or collapsing a row. It
  overrides tail following, so the row the reader clicked does not move away
  from the pointer.
- **A3: `.scrollOffset`** anchors the offset `o` itself. This is
  `NSTableView`'s behaviour, available for a host that wants it.

### 6.2 Carrying the anchor through the batch

- **A4: renumbering.** A row anchor follows its row through the batch's
  inserts, removals and moves, which apply one at a time (U2).
- **A5: a removed anchor row.** If the anchor row is removed, the anchor passes
  to the first surviving row after it, which keeps its own pre-batch screen
  position. If no row after it survives, the anchor passes to the last
  surviving row before it, on the same terms.
  - "Surviving" means neither removed nor moved, as in M2. A moved row keeps
    its pre-batch screen position only as its motion's start, so holding the
    viewport on it would carry the viewport to wherever the row went.
  - If no surviving row remains, the anchor becomes the offset: `o' = o`,
    then A7. That covers a batch that moved every remaining row, one that
    replaced every row, and one that emptied the list (where A7 gives
    `oMin`). A batch that replaces every row is then anchored the way
    `reloadData()` is (A9).

### 6.3 Restoring

- **A6: restoring each kind of anchor.**
  - tail → `o' = oMax'`
  - row `(a, d)` → `o' = y'(a') − t − d`
  - offset → `o' = o`
- **A7: clamping is the only exception.** `o'` is then clamped to
  `[oMin', oMax']`. This is the only case in which the anchor's screen position
  changes. In an animated commit the clamp animates too (M3), so it moves
  rather than jumps.
- **A8: tail following depends only on position.** "Following the tail" means
  `automaticallyFollowsTail` is on and the viewport is at the tail. It is
  re-evaluated after every commit and every scroll. No hidden flag remembers
  how the viewport got there. `isFollowingTail` reports it, and
  `listView(_:didChangeTailFollowing:)` fires only when it changes, starting
  from the value it had at the load point.
- **A9: `reloadData()`** anchors the tail if following, otherwise the offset.
  The rows after a reload may have nothing to do with the rows before it.

### 6.4 Viewport and configuration changes

- **V1: viewport height.** A change of `V` (a window resize, or a pane above or
  below growing) is a commit with `.automatic` anchoring, resolved against the
  viewport as it was before the change. The tail stays the tail. It never
  animates: the frame change that causes it is already the motion.
- **V2: content insets.** A change of `contentInsets` works the same way as V1.
  A floating bar that grows at the bottom while the viewport is following the
  tail therefore lifts the last row with it.
- **V3: row spacing.** A change of `rowSpacing` is a geometry commit with
  `.automatic` anchoring. It asks for no heights, and it never animates.
- **V4: turning tail following on or off.** Setting `automaticallyFollowsTail`
  re-evaluates A8 and moves nothing.
- **V5: settings before loading.** `contentInsets`, `rowSpacing` and
  `automaticallyFollowsTail` can be set at any time. Before the load point they
  are stored, and the load uses them.

---

## 7. Updates and commits

- **U1: synchronous commit.** A batch commits before the call that announced it
  returns. After that, every query and every mounted view's model frame is
  final. During an animation, only the presentation layers differ (§8).
- **U2: NSTableView's index semantics.** Inside a batch, updates apply
  **incrementally, in call order**: each index refers to the rows as they are
  after the preceding calls. This matches `NSTableView`, whose docs say
  changes are processed incrementally, and not `NSCollectionView`, which
  reorders updates into deletes, then inserts, then moves.
  - `insertRows(at:)`: the indexes are in the post-insert numbering.
  - `removeRows(at:)`: the indexes are in the pre-removal numbering.
  - `moveRow(at:to:)`: the same as a removal followed by an insert, except that
    the same view carries over.
- **U3: the batch closure receives a proxy.**
  `performBatchUpdates(anchoring:_:completionHandler:)` passes its closure an
  `ExactListView.Updates`. The proxy has only the update methods. Geometry
  cannot be queried in the middle of a batch, and nothing can be left
  unbalanced. The proxy stops with a precondition failure if it is used after
  its closure returns. Nested `performBatchUpdates` calls flatten into the
  outermost one. The outermost call's anchoring is the one that applies, and
  every completion handler runs when the outermost batch's animations end.
  *Deviation from `NSTableView`:* it uses `beginUpdates()`/`endUpdates()`
  instead. A closure makes an unbalanced pair impossible to write, and the
  proxy makes a query against half-applied geometry impossible to write.
- **U4: single calls.** `insertRows(at:withAnimation:)`,
  `removeRows(at:withAnimation:)`, `moveRow(at:to:)`,
  `reloadData(forRowIndexes:)` and `noteHeightOfRows(withIndexesChanged:)` on
  the list itself are each a batch of one with `.automatic` anchoring. Their
  names and semantics match `NSTableView`.
- **U5: when heights are asked.** Heights are asked at commit, never inside
  the closure. Inserted rows and noted rows are measured at `W`. So is any
  stale row the commit brings into `P`.
- **U6: reloading a row's contents.** `reloadData(forRowIndexes:)` asks for
  views again for the mounted rows among those indexes. If a different
  instance comes back, the old one goes back to the pool, and its host hears
  `didRemove`. Heights are not asked again, as in `NSTableView`. To change a
  height, note it.
- **U7: `reloadData()`.**
  - It removes every animation, and outstanding completion handlers get
    `false`.
  - It sends every mounted view to `didRemove`.
  - It asks for the count and every height again.
  - It anchors as A9 says. It never animates.
- **U8: completion handlers.** A batch's completion handler runs on the main
  actor, after the commit's animations have ended. It always runs
  asynchronously: at the earliest on the next run loop turn, even when nothing
  animated. It gets `true`, unless U7 cancelled it.

---

## 8. Motion

### 8.1 When a commit animates

- **M1: which commits animate.** A commit animates when its duration `T > 0`
  and Reduce Motion is off
  (`NSWorkspace.accessibilityDisplayShouldReduceMotion`).
  - `T` and the timing function are `NSAnimationContext.current.duration` and
    `.timingFunction`, read when the batch commits. Outside any group, AppKit's
    values are 0.25 s and `nil`, and this was measured. `nil` means
    `.easeInEaseOut`.
  - Updates animate by default, as `noteHeightOfRows` does in a view-based
    `NSTableView` (docs). A group with `duration = 0` turns animation off, which
    is AppKit's own recipe.
  - `reloadData()` and width changes never animate.
  - Scroll requests animate only when the current context's
    `allowsImplicitAnimation` is true. That is the AppKit rule for animating a
    view property set directly.

### 8.2 What the motion is

Let `p(t) = f(t / T)` be the curve's progress, from 0 to 1. Every row's
**screen top** is `y − o`: document position minus offset. Every row involved
in a commit has a start and an end value for its screen top and its height.

- **M2: linear interpolation.** At every `t`, each row's presented screen top
  and presented height are `end + (start − end)·(1 − p(t))`. The start and end
  values depend on the kind of row:
  - **Surviving:** start is the old screen top and height; end is the new ones.
  - **Inserted:** the end is its new frame. It starts at height 0 where its
    gap's old contents end, taking the first of these that exists:
    1. the old screen bottom of the gap's last removed row, plus `s`;
    2. the old screen bottom of the surviving row before the gap, plus `s`;
    3. the old screen top of the surviving row after the gap;
    4. its own end top.
  - **Removed:** the reverse. It starts at its old frame. It ends at height 0
    where its gap's new contents begin, taking the first of these that
    exists:
    1. the new screen top of the gap's first inserted row;
    2. the new screen bottom of the surviving row before the gap, plus `s`;
    3. the new screen top of the surviving row after the gap;
    4. its own start top.

    Only rows that were mounted before the commit are removed with motion;
    any other removed row is simply gone.
  - **Moved:** start is its old frame and end is its new frame. It has no
    neighbours (M10).

  **Gaps.** A **surviving** row is one that is neither inserted, removed nor
  moved. Surviving rows keep their relative order, so they cut the old and
  the new layout into the same gaps: before the first surviving row, between
  two consecutive ones, and after the last. A gap holds removed rows in the
  old layout and inserted rows in the new one (moved rows belong to no gap).
  Each rule above looks at the gap's other kind of row first. That is what
  keeps a removed and an inserted row in the same gap from overlapping: the
  inserted row opens below the space the removed row is closing.

  In a commit that doesn't animate, every row that has a motion has its start
  equal to its end, and no transition.

  **Which rows have a motion.** A row has one if its sweep (the hull of its
  start and end screen intervals, after M7) intersects `P`, measured against
  the viewport after the commit. `CommitPlan.motions` holds exactly these rows,
  in the order surviving and inserted rows by new index, then removed rows by
  old index.

  A row's content is laid out once, at its final size, and aligned to the top
  of its container. The container clips to the presented height, so a growing
  row is revealed and a shrinking row is covered up.
- **M3: how it is done.** This is realised with CoreAnimation and nothing else:
  - The model values are set to their final values.
  - Each affected row container gets an additive `position.y` animation from
    `(old screen y − new screen y)` to 0.
  - Each row whose height changes gets an additive `bounds.size.height`
    animation from `(old height − new height)` to 0.
  - All of these share `T` and `f`. Because presented positions are linear in
    `p`, this reproduces M2 exactly. Nothing runs per frame on the main thread,
    and no presentation layer is read.
- **M4: the anchor is still.** For a row anchor, the anchor row's presented
  screen position is constant for every `t`, unless A7 clamped it, in which
  case it moves along the linear interpolation.
- **M5: rows stay contiguous.** The **presented order** is the surviving
  rows in order, with each gap's removed rows (in old order) and then its
  inserted rows (in new order) between them. Moved rows are not in it. Take
  two rows that are consecutive in the presented order. At every `t`, the gap
  `presentedTop(next) − presentedBottom(row)` is the linear interpolation
  between its start and end values. Both of those values are ≥ 0, so rows
  never overlap.
  - If both rows survive and were adjacent before the commit too, the gap is
    exactly `s` at every `t`.
- **M6: no blank areas.** At every `t`, the presented rows and the spacing
  between them cover `U ∩ [0, H_presented(t)]`.
- **M7: the amplitude cap.** Let `C` be the height of `U`, and a row's `δ` be
  its end screen top minus its start screen top. The rows considered are the
  ones M2 gives start and end values to (every surviving, inserted and moved
  row, and every removed row that was mounted before the commit) whose
  unscaled sweep, the hull of their start and end screen intervals, meets
  `P`. If any of them has `|δ| > C`, every animation in the commit is scaled
  by the same factor `k = C / max|δ|` over those rows.
  - A uniform scale keeps M2 through M5. Each start value becomes
    `end + k·(start − end)`, which is still a convex combination of two
    layouts, so every gap stays ≥ 0 and the anchor still doesn't move.
  - It bounds how many rows have to be mounted during a long jump, which
    includes an animated scroll across the whole list.
- **M8: interruptions compose.** A commit made while earlier animations are
  still running adds its own animations on top; it removes none of them.
  Presented positions are continuous (C0) at the moment of the new commit. M4
  holds for the new commit's contribution.
- **M9: effects.** Inserted and removed rows take `NSTableView.AnimationOptions`:
  - `[]` and `.effectGap`: reveal or cover only (M2).
  - `.effectFade`: in addition, opacity goes 0 → 1 on insert and 1 → 0 on
    removal.
  - `.slideUp` / `.slideDown`: in addition, the content inside the clip is
    offset vertically by `∓h·(1 − p)`.
  - `.slideLeft` / `.slideRight`: the same, offset horizontally by `∓W·(1 − p)`.
- **M10: stacking order.** Moved rows are drawn above the others, and removed
  rows below them.
  - A moved row travels straight from its old screen position to its new one.
    Its old and new slots behave as a removal and an insertion (M5).
  - A removed row stays mounted until its animation ends. Its host then hears
    `didRemove` with row −1, as in `NSTableView`.

---

## 9. Width changes

- **W1: handled in the same pass.** The list handles a change of `W` inside the
  layout pass that produces it, before any row is displayed at the new width.
  The resize can come from a window, a split divider or an animator. The scroll
  view's tiling is where the list learns of the change.
- **W2: the anchor comes first.** The anchor is resolved as A1 says. For a row
  anchor, `d` is rescaled in proportion, `d' = d · h'(a) / h(a)`, so the
  reading position inside a reflowed row stays put. The tail stays the tail.
- **W3: exact in the prepared area.** Every row that intersects `P` under the
  new geometry is measured at the new `W` in the same pass. This repeats until
  `P`'s rows are all fresh; it terminates, because each round only adds rows.
  Rows outside `P` become **stale**: they keep their last measured height.
- **W4: no stale row is ever displayed.** A stale row that is about to intersect
  `P` because of a scroll, a commit or a later width change is measured at `W`
  before it is placed.
- **W5: stale rows are refreshed.** On idle run loop turns, the list measures
  stale rows outward from the anchor, nearest first and alternating down and
  up. It measures until a 4 ms budget per turn is spent, then commits without
  animation, anchored. Any width change cancels the pending batch and starts
  again. Each turn measures at least one row, so refreshing ends in a bounded
  number of turns.
- **W6: never twice at the same width.** No row is asked for its height at the
  width it was last measured at, unless it was inserted, noted or reloaded
  (U7) since. A row measured at `A`, then at `B`, is asked again when `W`
  returns to `A`: the list keeps one height per row, not one per width.

> **Note on the no-estimation rule.** Stale rows are the one place where the
> document isn't exact for the current `W`. Every number in it is still a
> height the delegate returned; nothing is sampled or extrapolated. The state
> is bounded in time (W5), and it never reaches the screen (W4). Measuring all
> `n` rows synchronously on every width change would put O(n) delegate calls
> on each frame of a divider drag.

---

## 10. Placement, reuse and views

- **P1: exact mounting.** After every commit, and after every scroll, the
  mounted set is:
  - every row whose model frame intersects `P`;
  - every row whose presented sweep intersects `P` while it is still
    animating;
  - every removed row that is still animating out;
  - every row that AppKit asked to prepare through `prepareContent(in:)` during
    responsive scrolling. That rect is AppKit's own overdraw, bounded to
    `P` extended by the height of `U` on each side. `NSTableView` answers the
    same call.

  No other row is mounted. Every mounted container's model frame equals G1's
  frame for its row. Mounting happens synchronously wherever the offset
  changes, so no row reaches the screen late. AppKit changes the offset by
  two routes, and neither calls the other (measured): `NSClipView.scroll(to:)`
  (the wheel, `scrollToVisible`, `NSView.scroll(_:)`) and `setBoundsOrigin(_:)`
  (`animator()`). Both are covered.
- **P2: views are asked for only on arrival.** `listView(_:viewForRow:)` is
  called when a row joins the mounted set, and by U6 — never at any other
  time. The returned view fills its row container, which is `W × h`, and the
  list sets that frame; the host does not.
- **P3: `didRemove` on departure.** `listView(_:didRemove:forRow:)` is called
  exactly once for every view that leaves the mounted set, after any animation
  it was part of has ended. The view then goes back into the pool under its
  `identifier`.
- **P4: reuse.** `makeView(withIdentifier:make:)` returns a pooled view with
  that identifier, or else the result of `make()` with the identifier set.
  *Deviation from `makeView(withIdentifier:owner:)`:* that method returns
  `NSView?` so that it can serve nibs. In code, it forces
  `as? Foo ?? Foo()` plus a manual `identifier` assignment, and forgetting that
  assignment silently disables recycling.
- **P5: row containers are internal.** Each mounted row sits in an internal
  container, the counterpart of `NSTableRowView`. The container carries the
  clipping and animations of §8, so the host's own view and layer are never
  given an animation or a mask.
  *Deviation:* `NSTableRowView` is public so that a host can draw selection;
  this list has no selection (§12).
- **P7: only mounted views are handed out.** `view(atRow:)` returns the
  mounted view, or `nil`. *Deviation:* `NSTableView`'s
  `view(atColumn:row:makeIfNecessary:)` can build a view for a row that is not
  on screen, which would break P1.
- **P6: `row(for:)`** returns the row of a mounted view or any of its
  descendants, and −1 otherwise, as in `NSTableView`. A view that is animating
  out answers −1.

---

## 11. Scrolling, keyboard, accessibility

- **S1: scrolling to a row.** `scrollRowToVisible(_:)` scrolls the least amount
  that brings row `i` fully into `U`. If the row is taller than `U`, the scroll
  aligns its top. A row above the viewport lands at the top of `U`, a row
  below it lands with its bottom exactly at the bottom of `U`, and a visible
  row doesn't move.
  *Deviation from `NSTableView`:* for a row above the viewport, a tall row
  and a clamped end they land at the same offset, but for a row below it
  `NSTableView` scrolls past the least amount (16 pt, measured), so "reveal
  this row" leaves an unexplained gap. The same name is kept, with the exact
  definition.
- **S2: scrolling to a position.** `scrollToRow(_:at:)` takes an
  `NSCollectionView.ScrollPosition`. The vertical members `.top`,
  `.centeredVertically`, `.bottom` and `.nearestHorizontalEdge` align the row
  to `U`, and the result is clamped by G3. Scrolling the last row to `.bottom`
  lands exactly on the tail.
  *Deviation:* `NSTableView` has no landing position; the shape is
  `NSCollectionView`'s.
- **S3: scrolls are commits.** A scroll is a commit with no geometry change
  whose anchor is its destination: the offset S1 or S2 computes, clamped by
  G3 (`CommitInput.targetOffset`, which takes the place of anchoring). An
  animated scroll is therefore M3 with a uniform `δ`, capped by M7.
- **S4: reader scrolling stays native.** Wheel, trackpad, momentum, elasticity
  and the scroller are `NSScrollView`'s own. A commit during a live scroll
  gesture adjusts the offset as §6 says, and the gesture carries on from there.
- **K1: keys.** The document view accepts first responder. It takes it on a
  click that no row consumed, as `NSTableView` does. It interprets keys with
  the standard key bindings.
  - The delegate is offered every command first, through
    `listView(_:doCommandBy:)` (the counterpart of `NSTextView`'s
    `textView(_:doCommandBy:)`).
  - Otherwise, the list answers only these commands:
    - `scrollLineUp`/`Down` and `moveUp`/`moveDown`, by `verticalLineScroll`;
    - `scrollPageUp`/`Down` and `pageUp`/`pageDown`, by the height of `U` minus
      `verticalPageScroll`;
    - `scrollToBeginningOfDocument` and `scrollToEndOfDocument`.
  - Every other key goes to the next responder as the original event.
- **X1: the table element.** The document view is the accessibility table
  (role `.table`, the same as `NSTableView`). `accessibilityRows()` has `n`
  elements, one per row, whether mounted or not. `accessibilityRowCount()` is
  `n`. `accessibilityVisibleRows()` lists the rows that intersect `U`.
- **X2: row elements.** Each row element has role `.row`, and its
  `accessibilityIndex()` is the row, and its parent is the table element. Its
  frame is `rect(ofRow:)` on screen: the committed frame, so during motion it
  is where the row is going. When the row is mounted, its children are
  `NSAccessibility.unignoredChildren(from: [view])` of the host view (the view
  itself if it is an element, else its unignored descendants, as a table row's
  cells are); otherwise it has none.
- **X3: unmounted rows.** An unmounted row is an `NSAccessibilityElement`,
  created the first time the table is asked for it, kept while its row exists
  (a client may hold it), and dropped when its row is removed and on
  `reloadData()`. Giving it accessibility
  focus (`setAccessibilityFocused(true)`, which is what VoiceOver does as it
  moves) scrolls as S1 says, and that mounts the row. The protocol has no
  scroll-to-visible method before macOS 26.
- **X4: stable elements.** Row elements are renumbered by commits, the same way
  anchors are (A4), so VoiceOver focus survives inserts above it.
- **X5: notifications.** A commit that changes `n` posts `.rowCountChanged`.

---

## 12. Not in this package

- **Content kinds** (`.line`, `.markdown`, …). Rows are host views; the list has
  no vocabulary of what is in them. A one-line text primitive belongs to its
  client (TranscriptKit).
- **Selection, columns, headers, group rows, type-select, drag and drop,
  custom row views.** None has a consumer (§14 governs adding one).
- **Self-sizing rows** (`usesAutomaticRowHeights`). Heights come only from the
  delegate. An Auto Layout solve per row, per width, contradicts G5 and B1.
- **A diffable data source.** `NSTableViewDiffableDataSource`'s shape assumes a
  settable data source (L1 forbids one), and nothing needs it yet. It comes back
  through §14 with a consumer.
- **Measuring off the main actor.** `heightOfRow` is synchronous. A host with
  expensive heights computes them ahead of time and answers from its own cache.
  If that proves insufficient (TranscriptKit's markdown is the known
  candidate), an asynchronous seam is added through §14.

---

## 13. Verification

"Real" means the test drives the same code path a user's interaction drives,
and its oracle is independent of the implementation.

| Layer | What runs | Oracle | Proves |
|---|---|---|---|
| **Core, property-based** (`ExactListCoreTests`, no AppKit) | Seeded random sequences, at least 10 000 batches per property: random heights, inserts, removals, moves, height notes, width changes and viewports. | A naive reference in the test file: an array of heights and linear sums, using only the heights the test itself generated. The planner's output is never its own oracle. | G1–G6, A1–A9, U2, M2, M4, M5, M7, W2, W3, W6 |
| **Window** (`ExactListTests`) | A real `NSWindow` off screen (the pattern of `cctermTests/Harness`, copied into the package, which cannot import the app's tests; the display-link sampler needs macOS 14 and is gated by `#available`) with a real layout pass, driven only through public API, `NSWindow.setFrame`, a real `NSSplitView` divider (including `animator()`) and synthesized `NSEvent`s. | A recording delegate that logs every call with its width, plus the test's own copy of the heights. | L1–L12, V1–V5, U1, U3–U8, W1, W4, W5, P1–P6, S1–S4, K1 |
| **Motion, frame by frame** | The same window, with a real commit. Two samplers: (a) a display-link sampler that reads `layer.presentation()` on every refresh, as the render server shows it; (b) deterministic scrubbing that freezes an ancestor layer's `CAMediaTiming` (`speed = 0`, `timeOffset = t`) and reads `presentation()` at chosen `t`. | M2's formulas, evaluated from the test's own old and new heights. | M1–M10 |
| **Accessibility** | In-process `NSAccessibility` protocol calls, the same methods the accessibility server calls. | Row count and indexes from the test's own model. | X1–X5 |
| **Characterization** (`NSTableViewCharacterizationTests`) | A real `NSTableView` in the same harness. | Assertions of its actual behaviour, which back §2. | §2 |
| **Benchmarks** (`ExactListBenchmarks`, `-O` only: `make bench-list`) | The same workloads against ExactList and against `NSTableView`, in one process. | Median wall time, and main-thread time per operation. | B1–B4 |
| **Demo** (`make demo-list`) | Human eyes, and VoiceOver by hand. | The checklist in `Sources/ExactListDemo/CLAUDE.md`. | What pixels and speech can't be asserted for |

**Programmer errors** (L9, L10, L12, U3's closed proxy) stop the process by
design, so they can't be observed from inside the test process. Each one is
run for real in a child process: `ExactListProbe`, a test-only executable,
mounts a list in a window, commits the named violation through the public
API, and dies. The test asserts that the child ended on a trap, and that the
message names the requirement.

What is **not** automatically covered, stated plainly:

- **Pixels on screen.** Presentation layers are what the render server
  composites, but the final pixels are only checked by eye in the demo.
- **Real VoiceOver speech.** Only the accessibility protocol is checked
  automatically; speech is a manual demo checklist.
- **A live trackpad gesture (S4).** A phased scroll event can't be
  synthesized in process: `NSScrollView` ignores one handed to
  `scrollWheel(with:)` and enters a tracking loop that waits on the real
  event queue for one sent through the window (both measured). The window
  tests cover the wheel, and a commit between wheel steps; a commit during a
  live gesture and momentum are the demo's checklist.

Benchmarks:

- **B1: scrolling.** Main-thread time per scroll step over a 10 000-row list is
  at most `NSTableView`'s.
- **B2: updates.** Appending, inserting at the top, noting a visible height and
  removing a range: each costs at most `NSTableView`'s time for the same
  update.
- **B3: width changes.** Per frame of a divider drag, the cost is at most
  `NSTableView`'s visible re-measure plus `noteHeightOfRows` of the visible
  rows.
- **B4: loading.** Loading 10 000 rows is reported against `NSTableView`'s
  `reloadData()` followed by a scroll to the end, which is what forces it to
  measure every row. The gate is 1.2× that.

**Traceability.** `SpecCoverageTests` parses every requirement ID in this file
and fails if any ID is not in some test's name.

---

## 14. Changing this spec

- Behaviour changes land here first, reviewed like the original. The code and
  the tests follow in the same PR.
- The **framework** is the package layout, the targets, the types, their files,
  and every signature, public and internal. It is frozen once committed.
  Filling in bodies never changes a signature. A change to the framework is an
  amendment to this spec: it states the reason, is reviewed, and is its own
  commit.
- TranscriptKit adopting this list is expected to need additions: a way to
  scroll to a rect inside a row, possibly floating overlays, possibly
  asynchronous measuring. Each one comes as an amendment, with TranscriptKit as
  its named consumer.

---

## 15. Structure (frozen with the framework)

```
macos/ExactList/
  Package.swift              ExactList (library) · ExactListDemo (executable)
                             ExactListTestSupport (test-only library)
                             ExactListProbe (test-only executable: programmer errors)
                             ExactListCoreTests · ExactListTests · ExactListBenchmarks
  SPEC.md  README.md  CLAUDE.md
  Sources/
    ExactListCore/           Foundation and CoreGraphics. The compiler keeps AppKit out.
    ExactList/               AppKit. Depends on ExactListCore.
    ExactListDemo/           Depends on ExactList.
```

Dependencies go one way: `ExactListDemo → ExactList → ExactListCore`. Core
imports no AppKit, and has no timers and no main-actor state. Hosts import
only `ExactList`, which re-exports the one Core type in its API (`Anchoring`).
Core imports Foundation and CoreGraphics, never AppKit.

**ExactListCore**: values and pure functions.

| Type | Owns |
|---|---|
| `Anchoring` | The public policy enum (§6.1). |
| `RowHeights` | The heights, the spacing, and a Fenwick index: G1–G5 queries, insert, remove, move, and set height. |
| `RowEdit` | One update in `NSTableView` semantics: insert, remove, move, note or reload. |
| `RowTransition` | The insert and remove effects. Its bits are `NSTableView.AnimationOptions`' raw values, so the engine converts between the two without a table (M9). |
| `RowIndexMap` | The old↔new index mapping of a batch, built incrementally from `RowEdit`s (U2). |
| `Viewport` | `o`, `V`, `t`, `b`, and what follows from them: `oMin`/`oMax`, `U`, `P`, and whether the viewport is at the tail. |
| `ScrollAnchor` | A resolved anchor (tail, row with `d`, or offset): resolution (A1–A3), renumbering (A4, A5), and restoring (A6, A7, W2). |
| `CommitInput` | Everything a commit is planned from: old and new heights, the map, old and new viewport, anchoring, or instead a scroll's destination (S3), tail following, whether to rescale the anchor (W2), the rows mounted before the commit, and whether it animates. |
| `RowMotion` | One row's start and end screen top and height, and its kind and transition (M2). |
| `CommitPlan` | A commit's outcome: the new offset, the resolved anchor, the `RowMotion`s, the amplitude `k`, and the tail state afterwards. |
| `CommitPlanner` | A pure function from `CommitInput` to `CommitPlan` (§6, §7, §8.2). |
| `StaleRows` | Which rows are stale, and the order to refresh them in, outward from the anchor (§9). |

**ExactList**: the AppKit engine. Every type is `@MainActor`.

| Type | Public? | Owns |
|---|---|---|
| `ExactListView` | yes | The façade: the public API, the lifecycle (§4), the batch entry points, and the width-change entry point. It holds the collaborators below. |
| `ExactListView.Updates` | yes | The batch proxy (U3). |
| `ExactListViewDataSource` | yes | `numberOfRows(in:)`. |
| `ExactListViewDelegate` | yes | `heightOfRow:width:`, `viewForRow:`, `didRemove:forRow:`, `didChangeTailFollowing:`, `doCommandBy:`. |
| `ListPhase` | no | Before or after the load point, and what was stored before it: settings and the last scroll request (L3–L6, V5). |
| `ListScrollView` | no | An `NSScrollView` subclass with the fixed configuration (L11). It reports width and viewport changes from `tile()` (W1, V1, V2). |
| `ListClipView` | no | An `NSClipView` subclass. It reports every change of the bounds origin, so mounting happens in the same turn as the scroll (P1). |
| `ListDocumentView` | no | The flipped document view: the first responder and keys (K1), `prepareContent(in:)` (P1), and the accessibility table (X1). |
| `RowContainerView` | no | The `NSTableRowView` counterpart: clipping, the host view's frame, and the accessibility row (X2). |
| `RowViewPool` | no | Reuse by identifier (P4). |
| `RowPlacement` | no | The mounted set, and mounting and unmounting against `P` (P1–P3, P6). |
| `MotionAnimator` | no | Turns a `CommitPlan` into CoreAnimation animations, retires rows once their animations end, and runs completion handlers (§8, U8). |
| `StaleRowRefresher` | no | Refreshing stale rows on idle turns within the time budget (W5). |
| `UnmountedRowElement` | no | The `NSAccessibilityElement` for a row that isn't mounted (X3). |

Collaborators never name `ExactListView`. Each talks back through one narrow
internal protocol that the façade conforms to: `ListScrollViewOwner`,
`ListClipViewOwner`, `ListDocumentViewOwner`, `RowPlacementOwner`,
`MotionAnimatorOwner`, `StaleRowRefresherOwner`, `UnmountedRowElementOwner`.

**ExactListTestSupport**: a test-only library, in no product. It holds the
window stage, the recording data source and delegate, the recording
`NSTableView` host that characterization and benchmarks run against, the
event synthesizer, the presentation sampler, the seeded generator and the
window-level reference layout that
`ExactListTests` and `ExactListBenchmarks` share. `ExactListCoreTests` keeps
its own reference, so Core stays testable with no AppKit linked.

Framework means everything internal or public. Private members are
implementation: filling in a body may add private stored properties and
private helpers, and nothing else.
