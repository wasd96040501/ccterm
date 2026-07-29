# TranscriptKit

A generic chat-transcript view for AppKit, packaged as a standalone Swift
package. Minimum platform: macOS 10.15.

> **Status: API skeleton.** The public surface below is the contract; the
> rendering implementation is not written yet.

## Design

The package exposes exactly one view, `TranscriptView`, and models its API
directly on `NSTableView`:

- **Data source, not data storage.** `TranscriptViewDataSource` answers
  `numberOfRows(in:)` and `transcriptView(_:contentForRow:)`; the host owns
  the backing data and announces every mutation through
  `insertRows(at:withAnimation:)` / `removeRows(at:withAnimation:)` /
  `reloadRows(at:)` / `reloadData()`, optionally batched with
  `beginUpdates()` / `endUpdates()`.
- **A closed content vocabulary.** `transcriptView(_:contentForRow:)` returns
  `TranscriptRowContent`, a fixed enum — not an open protocol:

  | Case | Payload | Drawn by | Height from |
  |---|---|---|---|
  | `.markdown` | one complete markdown document as `String` | the transcript | self-sizing |
  | `.userMessage` | message text as `String` | the transcript | self-sizing |
  | `.image` | `NSImage` | the transcript | self-sizing (aspect-fit to width) |
  | `.view` | none | a host `NSView` | the delegate |

  A markdown document is always one row; the view never splits it.
- **Data source says what, delegate says how** — the same split `NSTableView`
  draws. `TranscriptViewDataSource` answers row count and content;
  `TranscriptViewDelegate` answers the height and the view behind a `.view`
  row, and reports link activation and recycling.
- **Specialized row heights.** Self-sizing cases are measured by the view
  against its content width, and re-measured by it when that width changes.
  `.view` rows are sized by `transcriptView(_:heightOfRow:width:)`, asked for
  every such row — visible or not, since the scroller can't be sized without
  summing all of them. When a height goes stale without the content changing,
  the host invalidates it with `noteHeightOfRows(withIndexesChanged:)`, same
  semantics as `NSTableView`'s. The `width` parameter has no `NSTableView`
  counterpart: there, column widths were the host's to set in the first place.
- **Host views recycle.** `.view` carries no instance, only the fact that the
  row is the host's to draw. Instances come from
  `transcriptView(_:viewForRow:)`, called only for rows entering the viewport,
  where the host recycles through `makeView(withIdentifier:make:)`. A
  screenful of views serves a transcript of any length. Views that start
  animations or subscriptions stop them in
  `transcriptView(_:didRemove:forRow:)`.

  Splitting height from instance is what makes this work: were `.view` to
  carry an `NSView`, answering "how tall is row 8000" would mean building row
  8000's view, and recycling would never engage.
- **Scroll anchoring is built-in.** Changing row geometry never moves what the
  reader is looking at. Two rules, no switch, no observable state:

  1. Sitting at the bottom → follow the tail.
  2. Anywhere else → hold the viewport still, compensating for geometry
     changes *above* the visible content and ignoring those below it.

  Which one applies is decided by where the scroll offset is right now, never
  by which method last ran — dragging to the bottom re-engages tail following
  exactly the way an explicit scroll to the last row does. Both rules cover
  every mutation that moves geometry, including `noteHeightOfRows`.
  `scrollToRow(at:scrollPosition:)` is the deliberate exception.

  `NSTableView` promises none of this: `insertRows(at:withAnimation:)`
  documents only that `numberOfRows` grows and says nothing about the scroll
  offset. That suits lists whose top is stable; a transcript grows upward, so
  it doesn't.
- **Cold load is the host's, and needs no API.** A long transcript is loaded by
  rendering the first screen, then feeding the remainder in batches, one per
  `DispatchQueue.main.async` hop — each tick typesets a batch small enough to
  fit the frame budget. Nothing is observed, nothing is scheduled off the main
  thread, and the package needs no notion of pages or of where rows come from.

  Scroll anchoring is what makes this invisible: batches prepend above the
  viewport over several hundred milliseconds while the reader is already
  reading, and rule 2 holds the content still throughout.

## Usage sketch

```swift
let transcript = TranscriptView()
transcript.translatesAutoresizingMaskIntoConstraints = false
transcript.dataSource = self
view.addSubview(transcript)
// …activate constraints…
transcript.reloadData()

// Appending a message:
messages.append(newMessage)
transcript.insertRows(at: [messages.count - 1], withAnimation: .effectFade)
```

Serving a `.view` row — three calls, each at its own frequency:

```swift
// TranscriptViewDataSource — every row, cheap, no side effects.
func transcriptView(_ tv: TranscriptView, contentForRow row: Int) -> TranscriptRowContent {
    messages[row].isToolCall ? .view : .markdown(messages[row].text)
}

// TranscriptViewDelegate — every `.view` row, on screen or not.
// Measured from the model, never by building the view.
func transcriptView(_ tv: TranscriptView, heightOfRow row: Int, width: CGFloat) -> CGFloat {
    messages[row].toolGroup.height(fitting: width)
}

// TranscriptViewDelegate — only rows entering the viewport.
// Recycle, then bind idempotently.
func transcriptView(_ tv: TranscriptView, viewForRow row: Int) -> NSView {
    let cell = tv.makeView(withIdentifier: .toolGroup) { ToolGroupCellView() }
    cell.configure(with: messages[row].toolGroup)
    return cell
}

// That view later opened a disclosure and is now taller:
transcript.noteHeightOfRows(withIndexesChanged: [transcript.row(for: cell)])
```
