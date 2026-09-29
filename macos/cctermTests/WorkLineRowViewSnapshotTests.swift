import AppKit
import XCTest

@testable import ccterm

/// A run's row, its items, news, an error line and every accessory, light
/// and dark (design/transcript/01-run.md, 04-background.md). Review only —
/// `make test-unit FILTER=WorkLineRowViewSnapshotTests`, then open
/// `/tmp/ccterm-screenshots/WorkLineRowView.png`.
@MainActor
final class WorkLineRowViewSnapshotTests: XCTestCase {
    private func tile(_ kind: ToolKind, _ state: Tile.State = .done) -> Tile {
        Tile(glyph: .tool(kind), state: state)
    }

    private func model(
        _ line: WorkLine, _ level: WorkLineRowView.Model.Level = .line,
        _ action: WorkLineRowView.Model.Action = .toggle("r", expanded: false), origin: String? = nil,
        error: String? = nil, selected: Bool = false, flashes: Bool = false
    ) -> WorkLineRowView.Model {
        WorkLineRowView.Model(
            line: line, level: level, action: action, origin: origin, error: error, isSelected: selected,
            flashes: flashes)
    }

    private func line(
        _ kind: ToolKind, _ state: Tile.State = .done, text: StyledText, detail: String? = nil,
        exceptions: StyledText = StyledText(), meta: StyledText = StyledText()
    ) -> WorkLine {
        WorkLine(tile: tile(kind, state), text: text, detail: detail, exceptions: exceptions, meta: meta)
    }

    private var stat: StyledText {
        StyledText("+12", style: .added) + StyledText(" ") + StyledText("−3", style: .removed) + StyledText("  34s")
    }

    private var rows: [WorkLineRowView.Model] {
        let file = { (name: String) in StyledText(name, style: .noun(opens: name)) }
        let run = line(
            .change, text: StyledText("Edited ") + file("TranscriptView.swift") + StyledText(", ran 3 commands"),
            exceptions: StyledText(" · ") + StyledText("1 failed", style: .failure), meta: stat)
        let selectedRun = line(.change, text: StyledText("Edited 3 files, ran 2 commands"), meta: stat)
        let single = line(
            .command, text: StyledText("Build the package"), detail: "swift build -c debug --product ccterm",
            meta: StyledText("6s"))
        let failed = line(
            .command, .failed, text: StyledText("Run the unit tests"), detail: "make test-unit FILTER=Tran…",
            exceptions: StyledText(" · ") + StyledText("Failed", style: .failure))
        let news = line(
            .command,
            text: StyledText("Background command ") + StyledText("“Run tests”", style: .code)
                + StyledText(" finished"), meta: StyledText("4m"))
        let running = line(
            .read, .running, text: StyledText("Reading ") + file("LibraryStore.swift"), meta: StyledText("12s"))
        let waiting = line(.command, .waiting, text: StyledText("Waiting for your approval"))
        let long = line(
            .change,
            text: StyledText("Edited ") + file("TranscriptViewController.swift")
                + StyledText(", ran 3 commands and searched for ") + StyledText("rowSpacing", style: .code)
                + StyledText(" across the whole package"),
            detail: "macos/TranscriptKit/Sources/TranscriptKit/Internal/TranscriptView+Layout.swift",
            exceptions: StyledText(" · ") + StyledText("1 failed", style: .failure), meta: stat)
        return [
            model(run),
            model(run, .line, .toggle("r", expanded: true)),
            model(selectedRun, selected: true),
            model(single, .line, .open("b1")),
            model(single, .item, .open("b1")),
            model(
                failed, .item, .open("b2"),
                error: "error: 'rowSpacing' is inaccessible due to 'private' protection level"),
            model(single, .item, .open("b1"), selected: true),
            model(news, .line, .open("n1"), origin: "b1"),
            model(running, .item, .open("r1")),
            model(waiting, .line, .toggle("r", expanded: false)),
            model(long),
        ]
    }

    func testEveryShape() {
        RowSnapshot.render(WorkLineRowView.self, rows, gap: 2, name: "WorkLineRowView", test: self)
    }

    /// The pointer over a row: the wash, the arrow that opens beside, ↖.
    func testHovered() {
        let rows = [rows[3], rows[4], rows[7], rows[0]]
        RowSnapshot.render(
            WorkLineRowView.self, rows, gap: 2, name: "WorkLineRowViewHovered",
            prepare: { view, _ in
                let event = NSEvent.enterExitEvent(
                    with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                    context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
                view.mouseEntered(with: event)
            }, test: self)
    }

    func testNarrow() {
        RowSnapshot.render(
            WorkLineRowView.self, rows, widths: [320], gap: 2, name: "WorkLineRowViewNarrow", test: self)
    }
}
