# TranscriptKit

A generic chat-transcript view for AppKit, packaged as a standalone Swift
package. Minimum platform: macOS 10.15.

> **Status: API skeleton.** The public surface below is the contract; the
> rendering implementation is not written yet.

## Design

The package exposes exactly one view, `TranscriptView`, and models its API
directly on `NSTableView`:

- **Data source, not data storage.** `TranscriptViewDataSource` answers
  `numberOfRows(in:)` and `transcriptView(_:rowAt:)`; the host owns
  the backing data and announces every mutation through
  `insertRows(at:)` / `removeRows(at:)` /
  `reloadRows(at:)` / `reloadData()`, optionally batched with
  `beginUpdates()` / `endUpdates()`.
- **Rows are identified by the host.** `transcriptView(_:rowAt:)` hands back a
  `TranscriptRow` — an id and a content, in one answer. The id is whatever the
  host already uses to tell its rows apart (a `UUID`, a message number), and it
  is what everything the transcript computes for a row is filed under. Row
  numbers move; identities do not, so an insertion above a row, a removal, a
  reorder and a `reloadData` all cost nothing.
- **A closed content vocabulary.** `TranscriptRowContent` is a fixed enum — not
  an open protocol:

  | Case | Payload | Drawn by | Height from |
  |---|---|---|---|
  | `.markdown` | one complete markdown document as `String` | the transcript | self-sizing |
  | `.userMessage` | message text as `String` | the transcript | self-sizing |
  | `.view` | none | a host `NSView` | the delegate |

  A markdown document is always one row; the view never splits it. Anything
  richer than these — tool cards, attachment strips, pictures — is a `.view`.
- **Data source says what, delegate says how** — the same split `NSTableView`
  draws. `TranscriptViewDataSource` answers row count and content;
  `TranscriptViewDelegate` answers the height and the view behind a `.view`
  row, and reports link activation and recycling.
- **Specialized row heights.** Self-sizing cases are measured by the view
  against its content width, and re-measured by it when that width changes.
  `.view` rows are sized by `transcriptView(_:heightOfRow:width:)`, asked for
  far more rows than are visible — `NSTableView` measures a working set of a few
  hundred and extrapolates its scroll range from that. When a height goes stale
  without the content changing,
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
- **Cold load is the host's, in two phases.** A long transcript renders its
  first screen synchronously, then feeds the remainder in batches, one per hop.
  Up to a few thousand rows that is the whole story and needs no API: the
  package observes nothing and needs no notion of pages or of where rows come
  from.

  Past that, hops stop being enough — they divide one freeze into many rather
  than removing it. (`NSTableView` does not ask for every row's height: it
  measures a working set of a few hundred and extrapolates the rest. But a
  ten-thousand-row load still walks several thousand of them.) So a batch can be
  measured off the main actor first:

  ```swift
  let prepared = await transcript.prepareRows(
      batch.map { TranscriptRow(id: $0.id, content: .markdown($0.text)) })
  // no `await` between mutating the model and announcing it
  messages.insert(contentsOf: batch, at: 0)
  transcript.insertRows(at: IndexSet(0..<batch.count), warming: prepared)
  ```

  What is asynchronous is the **measure**, not the insert — `insertRows` stays
  synchronous and total, because suspending between the model changing and the
  transcript hearing about it is what makes the two disagree. Ten thousand rows
  of real markdown: 12.47 s of main thread the plain way, 0.12 s this way.

  The two arguments are unrelated: `indexes` says where rows appeared, `prepared`
  says which rows were already measured. Measurements are filed by identity, so
  anything at all may happen to the transcript while a batch is in flight.

  Scroll anchoring is what makes either phase invisible: batches prepend above
  the viewport while the reader is already reading, and rule 2 holds the content
  still throughout.

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
transcript.insertRows(at: [messages.count - 1])
```

Serving a `.view` row — three calls, each at its own frequency:

```swift
// TranscriptViewDataSource — every row, cheap, no side effects.
func transcriptView(_ tv: TranscriptView, rowAt row: Int) -> TranscriptRow {
    let message = messages[row]
    return TranscriptRow(
        id: message.id,
        content: message.isToolCall ? .view : .markdown(message.text))
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
