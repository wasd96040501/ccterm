import AppKit
import ExactList

/// The demo's model, data source and delegate: rows of wrapped text whose
/// heights are measured with the same typesetter the row view draws with.
@MainActor
final class DemoFeed: ExactListViewDataSource, ExactListViewDelegate {

    init() {
        fatalError("unimplemented: demo")
    }

    /// Runs one scenario against `list`.
    func run(_ scenario: DemoScenario, on list: ExactListView) {
        fatalError("unimplemented: demo")
    }

    func numberOfRows(in listView: ExactListView) -> Int {
        fatalError("unimplemented: demo")
    }

    func listView(_ listView: ExactListView, heightOfRow row: Int, width: CGFloat) -> CGFloat {
        fatalError("unimplemented: demo")
    }

    func listView(_ listView: ExactListView, viewForRow row: Int) -> NSView {
        fatalError("unimplemented: demo")
    }
}
