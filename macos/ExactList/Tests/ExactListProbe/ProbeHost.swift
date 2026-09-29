import AppKit
import ExactList

/// The probe's data source and delegate: fixed-height rows, and one hook that
/// runs inside `heightOfRow` for the scenario that misbehaves there.
@MainActor
final class ProbeHost: ExactListViewDataSource, ExactListViewDelegate {

    var count: Int
    var height: CGFloat = 30
    var insideHeight: ((ExactListView) -> Void)?

    init(count: Int) {
        self.count = count
    }

    func numberOfRows(in listView: ExactListView) -> Int {
        count
    }

    func listView(_ listView: ExactListView, heightOfRow row: Int, width: CGFloat) -> CGFloat {
        insideHeight?(listView)
        return height
    }

    func listView(_ listView: ExactListView, viewForRow row: Int) -> NSView {
        listView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("probe")) { NSView() }
    }
}
