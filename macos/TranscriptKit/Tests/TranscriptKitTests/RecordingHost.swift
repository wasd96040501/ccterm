import AppKit
import TranscriptKit

/// A host that answers every row from a list of heights with a plain view, and
/// records what it was asked.
///
/// Heights are uniform unless a test says otherwise, so row geometry stays exact
/// arithmetic: row *n* starts at `n * rowHeight`. The recordings are the other
/// half — most of what is worth asserting about the transcript is not "what does
/// it look like" but "how many times, and at what width, did it ask".
///
/// The mutators change only this list. Announcing the change to the transcript is
/// left to the test, so both halves of what a host does sit next to each other at
/// the call site — and a test that forgets the announcement fails the way a host
/// that forgets it would.
@MainActor
final class RecordingHost: NSObject, TranscriptViewDataSource, TranscriptViewDelegate {

    /// A hosted view distinguishable from the transcript's own cell views when
    /// walking the tree.
    final class ProbeView: NSView {}

    private(set) var heights: [CGFloat]

    /// The `width` argument of every `heightOfRow` call, in order.
    private(set) var heightWidths: [CGFloat] = []
    private(set) var viewCalls = 0
    /// How many times `makeView` had to build rather than recycle.
    private(set) var builds = 0
    private(set) var removals: [Int] = []

    init(rowCount: Int, rowHeight: CGFloat = 40) {
        heights = Array(repeating: rowHeight, count: rowCount)
        super.init()
    }

    func resetRecordings() {
        heightWidths = []
        viewCalls = 0
        builds = 0
        removals = []
    }

    // MARK: - Model mutations

    func insertRows(_ count: Int, at index: Int, height: CGFloat = 40) {
        heights.insert(contentsOf: Array(repeating: height, count: count), at: index)
    }

    func removeRows(at indexes: IndexSet) {
        for index in indexes.sorted(by: >) { heights.remove(at: index) }
    }

    func setHeight(_ height: CGFloat, forRow row: Int) {
        heights[row] = height
    }

    // MARK: - Data source and delegate

    func numberOfRows(in transcriptView: TranscriptView) -> Int {
        heights.count
    }

    func transcriptView(
        _ transcriptView: TranscriptView, contentForRow row: Int
    ) -> TranscriptRowContent {
        .view
    }

    func transcriptView(
        _ transcriptView: TranscriptView, heightOfRow row: Int, width: CGFloat
    ) -> CGFloat {
        heightWidths.append(width)
        return heights[row]
    }

    func transcriptView(
        _ transcriptView: TranscriptView, viewForRow row: Int
    ) -> NSView {
        viewCalls += 1
        return transcriptView.makeView(withIdentifier: .probe) {
            builds += 1
            return ProbeView()
        }
    }

    func transcriptView(_ transcriptView: TranscriptView, didRemove view: NSView, forRow row: Int) {
        removals.append(row)
    }
}

extension NSUserInterfaceItemIdentifier {
    fileprivate static let probe = NSUserInterfaceItemIdentifier("test.probe")
}
