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

  | Case | Payload | Height |
  |---|---|---|
  | `.markdown` | one complete markdown document as `String` | self-sizing |
  | `.userMessage` | message text as `String` | self-sizing |
  | `.image` | `NSImage` | self-sizing (aspect-fit to width) |
  | `.view` | caller-owned `NSView` + `height: CGFloat` | fixed by caller |

  A markdown document is always one row; the view never splits it.
- **Specialized row heights.** There is no `heightOfRow` delegate callback.
  Self-sizing cases are measured by the view against its layout width; a
  `.view` row is pinned at the caller-supplied height. When a fixed height
  must change, the caller invalidates it with
  `noteHeightOfRows(withIndexesChanged:)` — same semantics as
  `NSTableView.noteHeightOfRows(withIndexesChanged:)` — and the row content
  is re-queried.
- **Display events go to a thin delegate.** `TranscriptViewDelegate` reports
  link activation; every requirement has a default no-op implementation.
- **Tail following is built-in.** While the view sits at the bottom, new and
  growing content keeps the tail visible; scrolling away suspends it until
  the user scrolls back or the host calls `scrollToTail(animated:)`. There
  is no switch and no observable state for it.

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

// A fixed-height `.view` row changed its height:
transcript.noteHeightOfRows(withIndexesChanged: [row])
```
