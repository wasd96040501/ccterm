import AppKit

/// The same rows and scenarios as `DemoFeed`, on a plain `NSTableView`, for
/// comparing the two side by side. Each scenario is written the way an
/// `NSTableView` host would write it; where the table has no counterpart to
/// what the list does, the nearest native idiom stands in:
/// - Following the tail: after an arrival at the tail, the clip view scrolls
///   to the new end through `animator()`, as the insert animates.
/// - Scrolling to the top: the clip view's origin through `animator()`.
/// - Rows above the viewport: nothing holds what the reader sees; the table
///   keeps its offset, as it does.
@MainActor
public final class DemoTableFeed: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    /// The table in its scroll view, configured like the demo's list: one
    /// column, no header, no selection, 6 pt between rows and 8 pt above and
    /// below the content.
    public let scrollView = NSScrollView()

    public override init() {
        rows = (0..<60).map { Row(text: DemoFeed.text(for: $0), expanded: $0 % 4 == 0) }
        nextNumber = rows.count
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("DemoColumn"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 6)
        table.usesAutomaticRowHeights = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
    }

    /// Scrolls to the end, as the list loads at its tail.
    public func scrollToEnd() {
        let clip = scrollView.contentView
        clip.setBoundsOrigin(endOrigin)
        scrollView.reflectScrolledClipView(clip)
    }

    /// Runs one scenario against the table.
    public func run(_ scenario: DemoScenario) {
        timer?.invalidate()
        timer = nil
        switch scenario {
        case .stream:
            repeatEvery(0.35, times: 20) { [weak self] in
                guard let self else { return }
                let following = isAtEnd
                rows.append(Row(text: DemoFeed.text(for: takeNumber()), expanded: true))
                NSAnimationContext.runAnimationGroup { _ in
                    self.table.insertRows(at: [self.rows.count - 1], withAnimation: .effectFade)
                    if following { self.scrollToEndAnimated() }
                }
            }
        case .growLastRow:
            repeatEvery(0.08, times: 80) { [weak self] in
                guard let self, !rows.isEmpty else { return }
                let following = isAtEnd
                let last = rows.count - 1
                rows[last].expanded = true
                rows[last].text += " " + DemoFeed.words[(rows[last].text.count / 5) % DemoFeed.words.count]
                configureView(ofRow: last)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.08
                    context.timingFunction = CAMediaTimingFunction(name: .linear)
                    self.table.noteHeightOfRows(withIndexesChanged: [last])
                    if following { self.scrollToEndAnimated() }
                }
            }
        case .toggleClicked:
            let visible = table.visibleRect
            let row = table.row(at: NSPoint(x: visible.midX, y: visible.midY))
            if row >= 0 { toggle(row: row) }
        case .churnAbove:
            if table.rows(in: table.visibleRect).location < 12 {
                table.scrollRowToVisible(0)
                table.scroll(NSPoint(x: 0, y: table.rect(ofRow: min(30, rows.count - 1)).minY))
            }
            var inserting = true
            repeatEvery(0.5, times: 16) { [weak self] in
                guard let self else { return }
                let first = table.rows(in: table.visibleRect).location
                guard first >= 6 else { return }
                if inserting {
                    let at = first - 4
                    let arriving = [takeNumber(), takeNumber()].map {
                        Row(text: DemoFeed.text(for: $0), expanded: true)
                    }
                    rows.insert(contentsOf: arriving, at: at)
                    table.insertRows(at: IndexSet(integersIn: at..<(at + 2)), withAnimation: .effectFade)
                } else {
                    let at = first - 5
                    rows.removeSubrange(at..<(at + 2))
                    table.removeRows(at: IndexSet(integersIn: at..<(at + 2)), withAnimation: .effectFade)
                }
                inserting.toggle()
            }
        case .toggleSidebar:
            // DemoContentViewController animates its split view; the table follows.
            break
        case .loadLarge:
            rows = (0..<10_000).map { Row(text: DemoFeed.text(for: $0), expanded: $0 % 3 == 0) }
            nextNumber = rows.count
            table.reloadData()
            scrollToEnd()
        case .scrollToTop:
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.6
                scrollView.contentView.animator().setBoundsOrigin(
                    NSPoint(x: 0, y: -scrollView.contentInsets.top))
            }
        }
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let width = tableView.tableColumns.first?.width ?? tableView.bounds.width
        return DemoRowView.height(for: rows[row].text, expanded: rows[row].expanded, width: width)
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view =
            tableView.makeView(withIdentifier: Self.rowIdentifier, owner: nil) as? DemoRowView
            ?? {
                let view = DemoRowView(frame: .zero)
                view.identifier = Self.rowIdentifier
                return view
            }()
        view.configure(text: rows[row].text, expanded: rows[row].expanded)
        view.onToggle = { [weak self, weak view] in
            guard let self, let view else { return }
            let row = table.row(for: view)
            if row >= 0 { toggle(row: row) }
        }
        return view
    }

    public func tableViewColumnDidResize(_ notification: Notification) {
        // Wrapped text: every height depends on the width. Without animation,
        // as the width itself isn't animated row by row.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
        }
    }

    // MARK: - Private

    private struct Row {
        var text: String
        var expanded: Bool
    }

    private static let rowIdentifier = NSUserInterfaceItemIdentifier("DemoTableRow")

    private let table = NSTableView()

    private var rows: [Row]

    private var nextNumber: Int

    private var timer: Timer?

    /// Within a point of the end of the content.
    private var isAtEnd: Bool {
        let clip = scrollView.contentView
        return clip.bounds.maxY >= table.frame.maxY + scrollView.contentInsets.bottom - 1
    }

    /// The clip view's origin with the end of the content, and the inset
    /// below it, at the bottom.
    private var endOrigin: NSPoint {
        let clip = scrollView.contentView
        let end = table.frame.maxY + scrollView.contentInsets.bottom - clip.bounds.height
        return NSPoint(x: 0, y: max(-scrollView.contentInsets.top, end))
    }

    private func scrollToEndAnimated() {
        scrollView.contentView.animator().setBoundsOrigin(endOrigin)
    }

    private func takeNumber() -> Int {
        defer { nextNumber += 1 }
        return nextNumber
    }

    /// The content changes first and the height follows, as the list's host
    /// does.
    private func toggle(row: Int) {
        rows[row].expanded.toggle()
        configureView(ofRow: row)
        table.noteHeightOfRows(withIndexesChanged: [row])
    }

    private func configureView(ofRow row: Int) {
        (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? DemoRowView)?
            .configure(text: rows[row].text, expanded: rows[row].expanded)
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
}
