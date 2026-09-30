import AppKit
import ExactList

// `ExactListProbe <scenario>`: mounts a list, loads it, then commits the
// scenario's programmer error through the public API. Every scenario ends in a
// precondition failure; reaching the end is itself the failure, exit 0.
MainActor.assumeIsolated {
    guard CommandLine.arguments.count == 2, let scenario = ProbeScenario(rawValue: CommandLine.arguments[1]) else {
        FileHandle.standardError.write(Data("usage: ExactListProbe <scenario>\n".utf8))
        exit(64)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let window = NSWindow(
        contentRect: NSRect(x: -30_000, y: -30_000, width: 400, height: 300), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    var host: ProbeHost? = ProbeHost(count: 20)
    let list = ExactListView(dataSource: host!, delegate: host!)
    list.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    window.contentView = list
    window.orderFrontRegardless()
    if scenario.loadsFirst { list.layoutSubtreeIfNeeded() }

    switch scenario {
    case .updateInsideCallback:
        host!.insideHeight = { $0.insertRows(at: [0]) }
        host!.count += 1
        list.insertRows(at: [0])
    case .reloadInsideBatch:
        list.performBatchUpdates { list.reloadData() }
    case .scrollInsideCallback:
        host!.insideHeight = { $0.scrollRowToVisible(0) }
        list.noteHeightOfRows(withIndexesChanged: [0])
    case .queryInsideBatch:
        list.performBatchUpdates { _ = list.rect(ofRow: 0) }
    case .countMismatch:
        list.insertRows(at: [0])
    case .invalidHeight:
        host!.height = .nan
        host!.count += 1
        list.insertRows(at: [0])
    case .zeroHeight:
        host!.height = 0
        list.noteHeightOfRows(withIndexesChanged: [0])
    case .negativeSpacing:
        list.rowSpacing = -1
    case .infiniteSpacing:
        list.rowSpacing = .infinity
    case .indexOutOfRange:
        list.removeRows(at: [50])
    case .anchorOutOfRange:
        list.performBatchUpdates(anchoring: .row(50)) { list.noteHeightOfRows(withIndexesChanged: [0]) }
    case .scrollOutOfRange:
        list.scrollToRow(50, at: .top)
    case .pendingScrollOutOfRange:
        list.scrollRowToVisible(50)
        list.layoutSubtreeIfNeeded()
    case .deallocatedDataSource:
        host = nil
        list.reloadData()
    case .deallocatedBeforeLoad:
        host = nil
        list.layoutSubtreeIfNeeded()
    case .deallocatedBeforePlacement:
        host = nil
        list.scrollToRow(19, at: .top)
    }
    FileHandle.standardError.write(Data("scenario \(scenario.rawValue) did not trap\n".utf8))
    exit(0)
}
