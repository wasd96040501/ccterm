import AppKit
import XCTest

@testable import ccterm

/// A press on a work line: on a named file that is a link it opens that
/// file's document; anywhere else it does what the line does — a run's
/// toggles. The line's words are drawn, so which characters are under the
/// pointer is the row's own arithmetic, held here.
@MainActor
final class WorkLineRowViewPressTests: XCTestCase {
    private final class Spy: PageRowViewDelegate {
        var events: [String] = []
        func rowView(_ rowView: NSView, open id: String, pinned: Bool) { events.append("open \(id)") }
        func rowView(_ rowView: NSView, toggle runID: String, all: Bool) { events.append("toggle \(runID)") }
        func rowView(_ rowView: NSView, showAllOf runID: String) { events.append("show all \(runID)") }
        func rowView(_ rowView: NSView, revealOrigin callID: String) { events.append("reveal \(callID)") }
        func rowView(_ rowView: NSView, decide decision: Decision, for callID: String) {}
    }

    func testTheNamedFileOpensItsDocumentAndTheRestTogglesTheRun() throws {
        let view = WorkLineRowView()
        let spy = Spy()
        view.delegate = spy
        let line = WorkLine(
            tile: Tile(glyph: .tool(.change), state: .done),
            text: StyledText("Edited ") + StyledText("A.swift", style: .noun(opens: "e1"))
                + StyledText(", ran 3 commands"),
            detail: nil, exceptions: StyledText(), meta: StyledText("34s"))
        view.configure(
            with: WorkLineRowView.Model(
                line: line, level: .line, action: .toggle("r1", expanded: false), origin: nil,
                isSelected: false, flashes: false))
        let host = NSViewController()
        host.view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 28))
        view.frame = host.view.bounds
        host.view.addSubview(view)
        let stage = AppKitStage.mount(host, size: CGSize(width: 520, height: 28))
        defer { stage.teardown() }
        view.frame = host.view.bounds
        view.layoutSubtreeIfNeeded()

        // Press every 2 pt along the middle of the line.
        var byX: [(CGFloat, String)] = []
        for x in stride(from: CGFloat(1), to: 520, by: 2) {
            spy.events = []
            let point = view.convert(NSPoint(x: x, y: 14), to: nil)
            let event = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: stage.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            view.mouseDown(with: event)
            byX.append((x, spy.events.first ?? "nothing"))
        }
        let opening = byX.filter { $0.1 == "open e1" }.map(\.0)
        XCTAssertFalse(opening.isEmpty, "no press opened the named file")
        let width = ("A.swift" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
        XCTAssertEqual(
            (opening.last ?? 0) - (opening.first ?? 0), width, accuracy: 4, "the link spans the file's name")
        let edited = ("Edited " as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
        XCTAssertEqual(opening.first ?? 0, 24 + edited, accuracy: 3, "the link starts where the name is drawn")
        XCTAssertTrue(
            byX.filter { !opening.contains($0.0) }.allSatisfy { $0.1 == "toggle r1" },
            "everywhere else toggles the run")
    }
}
