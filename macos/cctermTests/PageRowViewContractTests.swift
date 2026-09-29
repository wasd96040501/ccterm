import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// The contract every `.view` row keeps with TranscriptKit, so scrolling
/// never jitters (Content/Transcript/CLAUDE.md "Row views keep
/// `PageRowView`"). TranscriptKit sets a row's view to the height
/// `height(for:width:)` declared and never asks again until the row changes;
/// a view that needs more, lays out ambiguously, or moves its parts between
/// two configurations of the same row is what makes a screen shift.
///
/// For every fixture at every width, after `configure` and a layout at the
/// declared height:
/// - nothing is laid out outside the row, and no text is cut vertically;
/// - no view's layout is ambiguous;
/// - configuring the same model again, after another fixture, or a variant
///   that is only paint (`sameGeometry`), moves nothing.
///
/// A new row view adds a test here with fixtures for each of its shapes.
@MainActor
final class PageRowViewContractTests: XCTestCase {
    /// The content column's narrowest, a split editor's, and its widest.
    private static let widths: [CGFloat] = [320, 520, 720]

    private func assertContract<V: PageRowView>(
        _ type: V.Type, _ fixtures: [RowFixture<V.Model>], file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(fixtures.isEmpty, "no fixtures for \(V.self)", file: file, line: line)
        for width in Self.widths {
            let (view, cell) = mount(V())
            for fixture in fixtures {
                let label = "\(V.self) “\(fixture.name)” at \(width)"
                let height = V.height(for: fixture.model, width: width)
                XCTAssertGreaterThan(height, 0, label, file: file, line: line)
                let base = layout(view, in: cell, fixture.model, width: width, height: height)
                assertWithin(view, label, file: file, line: line)

                for (index, variant) in fixture.sameGeometry.enumerated() {
                    XCTAssertEqual(
                        V.height(for: variant, width: width), height, "\(label), variant \(index): height",
                        file: file, line: line)
                    XCTAssertEqual(
                        layout(view, in: cell, variant, width: width, height: height), base,
                        "\(label), variant \(index)", file: file, line: line)
                }
                for other in fixtures where other.name != fixture.name {
                    _ = layout(
                        view, in: cell, other.model, width: width, height: V.height(for: other.model, width: width))
                }
                XCTAssertEqual(
                    layout(view, in: cell, fixture.model, width: width, height: height), base,
                    "\(label): reconfigured after other rows", file: file, line: line)
            }
        }
    }

    /// Puts `view` in a cell the way `TranscriptCellView.install` does:
    /// pinned top and bottom to a cell whose frame the table writes, and as
    /// wide as the cell.
    private func mount<V: NSView>(_ view: V) -> (V, NSView) {
        let table = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1000))
        let cell = NSView()
        table.addSubview(cell)
        view.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            view.topAnchor.constraint(equalTo: cell.topAnchor),
            view.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
        ])
        return (view, cell)
    }

    /// Configures `view`, lays its cell out at the row's size as TranscriptKit
    /// would, and answers where every part of it landed.
    private func layout<V: PageRowView>(
        _ view: V, in cell: NSView, _ model: V.Model, width: CGFloat, height: CGFloat
    ) -> [NSRect] {
        view.configure(with: model)
        cell.frame = NSRect(x: 0, y: 0, width: width, height: height)
        cell.superview?.layoutSubtreeIfNeeded()
        return parts(of: view).map { alignmentRect(of: $0, in: view) }
    }

    private func assertWithin(_ view: NSView, _ label: String, file: StaticString, line: UInt) {
        for part in parts(of: view) {
            let rect = alignmentRect(of: part, in: view)
            let name = "\(label): \(type(of: part)) \(rect)"
            XCTAssertTrue(
                view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(rect), "\(name) is outside the row", file: file,
                line: line)
            XCTAssertFalse(part.hasAmbiguousLayout, "\(name) is ambiguous", file: file, line: line)
            guard let field = part as? NSTextField, let cell = field.cell, let font = field.font,
                !field.stringValue.isEmpty
            else { continue }
            // A label that truncates must still show one whole line; one that
            // wraps, every line it wraps to.
            let oneLine = ceil(NSLayoutManager().defaultLineHeight(for: font))
            let wrapped = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: field.bounds.width, height: 100_000))
            let needed = cell.wraps && field.maximumNumberOfLines != 1 ? wrapped.height : oneLine
            XCTAssertGreaterThanOrEqual(
                field.bounds.height + 0.5, needed, "\(name) cuts its text", file: file, line: line)
        }
    }

    /// Where `part` puts its content, in `view`'s coordinates: its alignment
    /// rect, so a label's cell padding is not taken for overflow.
    private func alignmentRect(of part: NSView, in view: NSView) -> NSRect {
        let rect = part.alignmentRect(forFrame: part.frame)
        return part.superview.map { $0.convert(rect, to: view) } ?? rect
    }

    /// Every visible view the row lays out; a control's own subviews are its
    /// business.
    private func parts(of view: NSView) -> [NSView] {
        view.subviews.filter { !$0.isHidden }.flatMap { $0 is NSControl ? [$0] : [$0] + parts(of: $0) }
    }

    // MARK: - The harness itself

    /// A row that breaks every clause: one label hangs below the height it
    /// declares, another is squeezed into it, and selecting it moves them.
    private final class BrokenRowView: NSView, PageRowView {
        weak var delegate: PageRowViewDelegate?
        private let hanging = NSTextField(labelWithString: "Two lines\nof text")
        private let squeezed = NSTextField(labelWithString: "Two lines\nof text")
        private var leading: NSLayoutConstraint!

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            for label in [hanging, squeezed] {
                label.translatesAutoresizingMaskIntoConstraints = false
                addSubview(label)
            }
            leading = hanging.leadingAnchor.constraint(equalTo: leadingAnchor)
            NSLayoutConstraint.activate([
                leading, hanging.topAnchor.constraint(equalTo: topAnchor),
                squeezed.leadingAnchor.constraint(equalTo: hanging.trailingAnchor),
                squeezed.topAnchor.constraint(equalTo: topAnchor),
                squeezed.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        convenience init() { self.init(frame: .zero) }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

        static func height(for model: Bool, width: CGFloat) -> CGFloat { 12 }

        func configure(with isSelected: Bool) { leading.constant = isSelected ? 8 : 0 }
    }

    func testTheHarnessCatchesARowThatOverflowsIsCutOrMoves() {
        var caught: [String] = []
        let options = XCTExpectedFailure.Options()
        options.issueMatcher = { issue in
            caught.append(issue.compactDescription)
            return true
        }
        XCTExpectFailure("the broken row breaks the contract", options: options) {
            assertContract(BrokenRowView.self, [RowFixture(name: "plain", model: false, sameGeometry: [true])])
        }
        for clause in ["is outside the row", "cuts its text", "variant 0"] {
            XCTAssertTrue(caught.contains { $0.contains(clause) }, "the harness misses “\(clause)”: \(caught)")
        }
    }

    // MARK: - Rows

    func testWorkLineRowView() {
        var s = MessageScript()
        s.call("b1", "Bash", #"{"command":"cd /r && make","description":"Build the package"}"#)
        s.result("b1", "Exit code 2\nerror: 'rowSpacing' is inaccessible", error: true)
        s.call("e1", "Edit", #"{"file_path":"/r/A.swift","old_string":"a","new_string":"b"}"#)
        s.result("e1")
        guard case .run(let run) = s.page.entries.first else { return XCTFail("no run") }
        func line(_ level: WorkLineRowView.Model.Level, _ item: RunItem?) -> WorkLineRowView.Model {
            WorkLineRowView.Model(
                line: item?.line ?? run.line, level: level,
                action: item.map { .open($0.id) } ?? .toggle(run.id, expanded: false), origin: nil, error: item?.error,
                isSelected: false, flashes: false)
        }
        func painted(_ model: WorkLineRowView.Model) -> [WorkLineRowView.Model] {
            var selected = model
            selected.isSelected = true
            var flashing = selected
            flashing.flashes = true
            return [selected, flashing]
        }
        let fixtures = [
            ("a run", line(.line, nil)), ("a failed item", line(.item, run.items[0])),
            ("an item", line(.item, run.items[1])),
        ].map { RowFixture(name: $0.0, model: $0.1, sameGeometry: painted($0.1)) }
        assertContract(WorkLineRowView.self, fixtures)
    }

    func testQuestionRowView() throws {
        func questions(_ json: String) throws -> [Tools.AskUserQuestion.Question] {
            try JSONDecoder().decode(Tools.AskUserQuestion.Input.self, from: Data(#"{"questions":\#(json)}"#.utf8))
                .questions
        }
        func question(_ json: String, answers: [String: String], waiting: Bool = false) throws -> Question {
            let use = ToolUseBlock(id: "q", name: "AskUserQuestion", input: MessageScript.json("{}"))
            let call = ToolCall(
                use: use, result: nil, kind: .other, state: waiting ? .waiting(reason: nil) : .done, startedAt: nil,
                finishedAt: nil)
            return Question(call: call, questions: try questions(json), answers: answers)
        }
        let one =
            #"[{"question":"Which library should we use for date formatting?","header":"Auth method","options":[{"label":"date-fns","description":"Small, tree-shakeable"},{"label":"Moment","description":""}],"multiSelect":false}]"#
        let long =
            #"[{"question":"Which of these approaches to reworking the tab bar do you want me to take, given that the split editor keeps its own tab strip and both must keep working when a document opens beside the transcript?","header":"","options":[{"label":"A very long option label that will not fit a narrow split editor at all","description":"and a description that is just as long as the label is, so both must truncate"},{"label":"Short","description":"x"}],"multiSelect":false}]"#
        let several =
            #"[{"question":"Which platforms?","header":"Targets","options":[{"label":"macOS","description":"14+"},{"label":"iOS","description":""},{"label":"visionOS","description":"Later"}],"multiSelect":true},{"question":"Ship it?","header":"Release","options":[{"label":"Yes","description":""},{"label":"No","description":""}],"multiSelect":false}]"#
        let answered = try question(one, answers: ["Which library should we use for date formatting?": "date-fns"])
        let otherAnswer = try question(one, answers: ["Which library should we use for date formatting?": "Moment"])
        let unanswered = try question(one, answers: [:])
        let severalAnswered = try question(several, answers: ["Which platforms?": "macOS, iOS", "Ship it?": "Yes"])
        let severalOther = try question(several, answers: ["Which platforms?": "visionOS", "Ship it?": "No"])
        let fixtures = [
            RowFixture(name: "answered", model: answered, sameGeometry: [otherAnswer, unanswered]),
            RowFixture(name: "long text and options", model: try question(long, answers: [:])),
            RowFixture(name: "several questions", model: severalAnswered, sameGeometry: [severalOther]),
            RowFixture(name: "waiting", model: try question(one, answers: [:], waiting: true)),
            RowFixture(name: "waiting, long", model: try question(long, answers: [:], waiting: true)),
            RowFixture(
                name: "waiting, several", model: try question(several, answers: [:], waiting: true)),
        ]
        assertContract(QuestionRowView.self, fixtures)
    }
}
