import AppKit
import ExactList

/// The demo's model, data source and delegate: rows of wrapped text whose
/// heights are measured with the same typesetter the row view draws with.
@MainActor
public final class DemoFeed: ExactListViewDataSource, ExactListViewDelegate {

    public init() {
        rows = (0..<60).map { Row(text: Self.text(for: $0), expanded: $0 % 4 == 0) }
        nextNumber = rows.count
    }

    /// Runs one scenario against `list`.
    public func run(_ scenario: DemoScenario, on list: ExactListView) {
        timer?.invalidate()
        timer = nil
        switch scenario {
        case .stream:
            repeatEvery(0.35, times: 20) { [weak self, weak list] in
                guard let self, let list else { return }
                rows.append(Row(text: Self.text(for: takeNumber()), expanded: true))
                list.insertRows(at: [rows.count - 1], withAnimation: .effectFade)
            }
        case .growLastRow:
            repeatEvery(0.08, times: 80) { [weak self, weak list] in
                guard let self, let list, !rows.isEmpty else { return }
                let last = rows.count - 1
                // Expanded in the same commit as the first growth.
                rows[last].expanded = true
                rows[last].text += " " + Self.words[(rows[last].text.count / 5) % Self.words.count]
                configureView(ofRow: last, in: list)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.08
                    context.timingFunction = CAMediaTimingFunction(name: .linear)
                    list.noteHeightOfRows(withIndexesChanged: [last])
                }
            }
        case .toggleClicked:
            // What a click on the disclosure of the row in the middle does. A
            // point can fall between two rows, so the first row across a band.
            let middle = list.rows(in: NSRect(x: 0, y: list.bounds.midY, width: list.bounds.width, height: 40))
            if let row = middle.first { toggle(row: row, in: list) }
        case .churnAbove:
            if list.rows(in: list.bounds).lowerBound < 12 {
                list.scrollToRow(min(30, rows.count - 1), at: .top)
            }
            var inserting = true
            repeatEvery(0.5, times: 16) { [weak self, weak list] in
                guard let self, let list else { return }
                let first = list.rows(in: list.bounds).lowerBound
                guard first >= 6 else { return }
                if inserting {
                    let at = first - 4
                    let arriving = [takeNumber(), takeNumber()].map { Row(text: Self.text(for: $0), expanded: true) }
                    rows.insert(contentsOf: arriving, at: at)
                    list.insertRows(at: IndexSet(integersIn: at..<(at + 2)), withAnimation: .effectFade)
                } else {
                    let at = first - 5
                    rows.removeSubrange(at..<(at + 2))
                    list.removeRows(at: IndexSet(integersIn: at..<(at + 2)), withAnimation: .effectFade)
                }
                inserting.toggle()
            }
        case .toggleSidebar:
            // DemoContentViewController animates its split view; the list follows.
            break
        case .loadLarge:
            rows = (0..<10_000).map { Row(text: Self.text(for: $0), expanded: $0 % 3 == 0) }
            nextNumber = rows.count
            list.reloadData()
        case .scrollToTop:
            NSAnimationContext.runAnimationGroup { context in
                context.allowsImplicitAnimation = true
                context.duration = 0.6
                list.scrollToRow(0, at: .top)
            }
        }
    }

    public func numberOfRows(in listView: ExactListView) -> Int {
        rows.count
    }

    public func listView(_ listView: ExactListView, heightOfRow row: Int, width: CGFloat) -> CGFloat {
        DemoRowView.height(for: rows[row].text, expanded: rows[row].expanded, width: width)
    }

    public func listView(_ listView: ExactListView, viewForRow row: Int) -> NSView {
        let view = listView.makeView(withIdentifier: Self.rowIdentifier) { DemoRowView(frame: .zero) }
        view.configure(text: rows[row].text, expanded: rows[row].expanded)
        view.onToggle = { [weak self, weak listView, weak view] in
            guard let self, let listView, let view else { return }
            // The row now, not when the view was handed out: rows above may
            // have come and gone since (P6).
            let row = listView.row(for: view)
            if row >= 0 { toggle(row: row, in: listView) }
        }
        return view
    }

    // MARK: - Private

    private struct Row {
        var text: String
        var expanded: Bool
    }

    private static let rowIdentifier = NSUserInterfaceItemIdentifier("DemoRow")

    private static let words = [
        "anchor", "viewport", "commit", "exact", "height", "motion", "reflow", "row", "scroll", "layer",
        "prefix", "offset", "tail", "sweep", "gap", "frame", "width", "measure", "list", "glyph",
    ]

    private var rows: [Row]

    private var nextNumber: Int

    private var timer: Timer?

    private func takeNumber() -> Int {
        defer { nextNumber += 1 }
        return nextNumber
    }

    /// Expands or collapses `row`, anchored on it so it stays under the
    /// pointer (A2).
    private func toggle(row: Int, in list: ExactListView) {
        rows[row].expanded.toggle()
        guard !rows[row].expanded else {
            configureView(ofRow: row, in: list)
            list.performBatchUpdates(anchoring: .row(row)) { $0.noteHeightOfRows(withIndexesChanged: [row]) }
            return
        }
        // Collapsing: the card keeps its text while it shrinks over it, and
        // shows the one line when it has.
        let view = list.view(atRow: row)
        list.performBatchUpdates(anchoring: .row(row)) {
            $0.noteHeightOfRows(withIndexesChanged: [row])
        } completionHandler: { [weak self, weak list] _ in
            guard let self, let list, let view else { return }
            let now = list.row(for: view)
            if now >= 0 { configureView(ofRow: now, in: list) }
        }
    }

    private func configureView(ofRow row: Int, in list: ExactListView) {
        (list.view(atRow: row) as? DemoRowView)?.configure(text: rows[row].text, expanded: rows[row].expanded)
    }

    private func repeatEvery(_ interval: TimeInterval, times: Int, _ body: @escaping @MainActor () -> Void) {
        var left = times
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
            MainActor.assumeIsolated {
                body()
                left -= 1
                if left == 0 { timer.invalidate() }
            }
        }
    }

    /// A header line, then a body whose length varies by row.
    private static func text(for number: Int) -> String {
        let header = "Row \(number) — \(words[number % words.count]) \(words[(number * 7) % words.count])"
        let count = 8 + (number * 37) % 70
        let body = (0..<count).map { words[($0 * 3 + number) % words.count] }.joined(separator: " ")
        return header + "\n" + body.prefix(1).uppercased() + body.dropFirst() + "."
    }
}
