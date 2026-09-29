# ExactList

A vertical list for AppKit, with exact row geometry, anchored scrolling and
CoreAnimation motion. It is an alternative to a single-column, view-based
`NSTableView`, and it keeps `NSTableView`'s vocabulary.

- Minimum platform: macOS 12.
- No dependencies.
- Behaviour is specified in [SPEC.md](SPEC.md), which is normative.
- The rules for changing the package are in [CLAUDE.md](CLAUDE.md).

## Why not `NSTableView`

| | `NSTableView` | ExactList |
|---|---|---|
| Row heights | Samples a few hundred rows and extrapolates the rest. | Every row is measured, and positions are exact prefix sums. |
| Scroll position when rows change | Unspecified. Content above the viewport pushes it around. | Stays put, by a stated rule you can override per update. |
| Animation | Row slides and the offset correction are separate, so the reader sees a jump. | One commit, then additive CoreAnimation. The anchor row never moves on any frame. |
| Setup order | Set the data source, mount, lay out, then `reloadData()`, in that order. | Inject at `init` and mount. It loads itself once it has a real width. |
| Width changes | You call `noteHeightOfRows`. | Rows on screen are re-measured in the same layout pass, and the rest follow on idle turns. |

`SPEC.md` §2 lists each claim together with the test that proves it.

## Usage

```swift
final class FeedViewController: NSViewController, ExactListViewDataSource, ExactListViewDelegate {
    private var items: [Item] = []
    private lazy var list = ExactListView(dataSource: self, delegate: self)

    override func loadView() {
        view = list  // or add it as a subview with constraints; there is no load step
    }

    // Data source: how many rows.
    func numberOfRows(in listView: ExactListView) -> Int { items.count }

    // Delegate: how tall at this width. Called for every row, so answer
    // from the model and don't build a view.
    func listView(_ listView: ExactListView, heightOfRow row: Int, width: CGFloat) -> CGFloat {
        ItemCell.height(for: items[row], width: width)
    }

    // Delegate: the view, only for rows arriving on screen. Recycle, then bind
    // every field.
    func listView(_ listView: ExactListView, viewForRow row: Int) -> NSView {
        let cell = listView.makeView(withIdentifier: .itemCell) { ItemCell() }
        cell.configure(with: items[row])
        return cell
    }
}
```

The updates use `NSTableView`'s names and index rules:

```swift
items.append(newItem)
list.insertRows(at: [items.count - 1], withAnimation: .effectFade)   // animates by default

items[3].isExpanded.toggle()
list.performBatchUpdates(anchoring: .row(3)) { updates in              // the row the reader clicked stays put
    updates.noteHeightOfRows(withIndexesChanged: [3])
}

NSAnimationContext.runAnimationGroup { context in                     // no animation: AppKit's own recipe
    context.duration = 0
    list.removeRows(at: [0, 1])
}
```

For a chat or a log, set `list.automaticallyFollowsTail = true`. While the
viewport sits at the end, it stays there as rows arrive and grow.
`listView(_:didChangeTailFollowing:)` tells you when to show a "jump to latest"
button.
