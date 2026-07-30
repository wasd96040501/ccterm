import AppKit
import TranscriptKit

/// A host that answers every row with a fixed height and a plain view, and
/// records what it was asked.
///
/// Fixed heights so row geometry is exact arithmetic: row *n* starts at
/// `n * rowHeight`. The recordings are the point — most of what is worth
/// asserting about the transcript is not "what does it look like" but "how many
/// times, and at what width, did it ask".
@MainActor
final class RecordingHost: NSObject, TranscriptViewDataSource, TranscriptViewDelegate {

    /// A hosted view distinguishable from the transcript's own cell views when
    /// walking the tree.
    final class ProbeView: NSView {}

    let rowHeight: CGFloat
    var rowCount: Int

    /// The `width` argument of every `heightOfRow` call, in order.
    private(set) var heightWidths: [CGFloat] = []
    private(set) var viewCalls = 0
    /// How many times `makeView` had to build rather than recycle.
    private(set) var builds = 0
    private(set) var removals: [Int] = []

    init(rowCount: Int, rowHeight: CGFloat = 40) {
        self.rowCount = rowCount
        self.rowHeight = rowHeight
        super.init()
    }

    func resetRecordings() {
        heightWidths = []
        viewCalls = 0
        builds = 0
        removals = []
    }

    func numberOfRows(in transcriptView: TranscriptView) -> Int {
        rowCount
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
        return rowHeight
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
