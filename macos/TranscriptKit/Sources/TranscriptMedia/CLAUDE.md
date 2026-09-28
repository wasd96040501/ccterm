# TranscriptMedia

The host-side media parts that TranscriptKit §4 keeps out of the renderer, written once so the demo and the app share them. It depends on nothing in the package: a grid is a plain `NSView` a host hands the transcript as a `.view` row, so no renderer type is needed, and nothing in the renderer can name a window, overlay or grid.

**The boundary is the name: pictures, how a group of them packs, and the viewer they open into.** A host component that isn't media doesn't go here — it gets its own target or a deliberate rename. Before changing the renderer for something new, ask whether it's picture-shaped (presentation with product decisions, a model the renderer would have to borrow); if so it belongs here.

| Type | Rule |
|---|---|
| `MosaicLayout` | A port of Telegram's `GroupedLayout.measure`, constants included (spacing 4, minimum 70, ratios clamped 0.667…1.7, target 4/3 of offered height) and its two quirks, marked in source (average ratio seeded at 1.0; a tall-leaning group allows four in its middle row). Not a grid: nothing is cropped, every picture keeps its proportion. Keep it a port — don't "fix" the quirks. |
| `ImageGridView` | The `.view` row drawn from those rects. Outer corners 17, inner 5 (square inner corners across a 4pt gap read as a crack). `snapshot(ofTile:)` supplies the still the viewer flies from. |
| `MediaOverlayWindow` | Telegram's `GalleryViewer` mechanism: a borderless transparent screen-sized window with the 90% black dimming as a layer-backed view **inside** it (a window background can't animate apart from its content). |
| `ImagePreviewView` | The content opened into the overlay; answers `MediaOverlayContent`'s one question — given the space, what rect it wants. |
| `MediaImageStore` | Size and bitmap cache. Internal, and the one singleton here: a process-level cache, reason in its doc comment. |

**The public surface is what a host builds a picture row and a preview from, nothing more:** `ImageGridView` (`init()`, `configure(with:)`, `onActivate`, `height(for:width:)`, `snapshot(ofTile:)`), `MediaOverlayWindow.present`, `MediaOverlayContent`, `ImagePreviewView(url:)`. `MosaicLayout` and `MediaImageStore` are internal — a host hands over URLs and gets pictures. Widen something only when a host needs it.

## `MediaOverlayWindow.animate(oldRect:newRect:)`

- The motion is a **`CASpringAnimation`** (mass 3, stiffness 1000, damping 500 — heavily overdamped, played linearly), re-timed from 0.5 s to 0.25 s with `speed`, not `duration` (a re-timed spring by duration is a different curve). `easeOut` is not a substitute.
- **A layer-backed `NSView`'s layer has `anchorPoint` (0, 0)**, so `position` is the frame origin and scale pivots on that corner. Animate origins alongside scale; rewriting around centres puts the model value off the animation's `toValue` and the layer snaps on the last frame.
- **Two views fly:** the content (scaled independently per axis, so squashed at the collapsed end) and a still of the source tile (crop and corners included) crossfading over it.
- **Deviation from Telegram:** the overlay is a **child window** of the host, so it orders, minimises and hides with the transcript's window and needs no focus grab. Telegram's re-take-key-on-resign is right for an app-global viewer; this is a panel over one document.

## Synchronous file read in the layout pass — accepted

`heightOfRow` → `ImageGridView.height` → `MediaImageStore.size(of:)` opens the file on a cache miss (~0.4 ms, dominated by touching the filesystem, not ImageIO; warm reads are a dictionary lookup). `NSTableView` asks every row's height at reload, so the cost is every picture in the transcript × 0.4 ms, once. Accepted because a transcript doesn't hold enough pictures to matter.

If it ever does: add a `prepare(_ urls:)` the host calls when the *message* arrives, so `size(of:)` is always warm. Don't answer a fallback size and re-layout on arrival — a picture row's shape must be settled before it's shown and never revised under the reader.

`MediaOverlayContent` keeps its single requirement despite one implementer: the shell genuinely has to ask its content for a size, and inlining it would fuse a window into an image view.

## When a long-message preview surface is built

`didActivateMoreInRow:` has no consumer yet. Whoever builds the surface:

- **Don't mount a second `TranscriptView` with one uncapped row.** Its `SurfaceLayer`s are sized to the row, so a pasted file becomes a backing store as tall as the file. Use `NSTextView` — it lays out by visible range and brings selection, find and copy; `UserMessage` is plain text, so the two agree without sharing code.
- **Give it its own font size, not a delta from the transcript's** — a column read at length alone on a dark screen is a different problem from a row read in passing.
- **Measure in a throwaway `NSLayoutManager` + `NSTextContainer`** at the target width; `widthTracksTextView` overwrites `containerSize`, so asking a configured text view answers one line.
