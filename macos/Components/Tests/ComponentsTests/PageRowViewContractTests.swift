import AppKit
import DisplayModels
import XCTest

@testable import Components
@testable import ComponentsDesign

/// The contract every `.view` row keeps with TranscriptKit, so scrolling
/// never jitters (Content/Transcript/CLAUDE.md "Row views keep
/// `PageRowView`"). TranscriptKit sets a row's view to the height
/// `height(for:width:)` declared and never asks again until the row changes;
/// a view that needs more, lays out ambiguously, or moves its parts between
/// two configurations of the same row is what makes a screen shift.
///
/// For every fixture at every width, after `configure` and a layout at the
/// declared height:
/// - nothing is laid out outside the row, and no text field's text is cut
///   vertically (drawn words — a work line's — are the snapshots' to show);
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
        // A run of two calls — a failed command and an edit — as the page words it.
        let run = WorkLine(
            tile: Tile(glyph: .tool(.change), state: .done),
            text: StyledText("Edited ") + StyledText("A.swift", style: .noun(opens: "e1"))
                + StyledText(", ran a command"),
            detail: nil, exceptions: StyledText("· ") + StyledText("1 failed", style: .failure),
            meta: StyledText.diffStat(added: 1, removed: 1))
        let failedItem = WorkLine(
            tile: Tile(glyph: .tool(.command), state: .failed), text: StyledText("Build the package"), detail: "make",
            exceptions: StyledText(), meta: StyledText())
        let editedItem = WorkLine(
            tile: Tile(glyph: .tool(.change), state: .done),
            text: StyledText("A.swift", style: .noun(opens: nil)), detail: ".", exceptions: StyledText(),
            meta: StyledText.diffStat(added: 1, removed: 1))
        func line(_ level: WorkLineRowView.Model.Level, _ item: (id: String, line: WorkLine)?) -> WorkLineRowView.Model
        {
            WorkLineRowView.Model(
                line: item?.line ?? run, level: level,
                action: item.map { .open($0.id) } ?? .toggle("b1", expanded: false), origin: nil,
                isSelected: false, flashes: false)
        }
        func painted(_ model: WorkLineRowView.Model) -> [WorkLineRowView.Model] {
            var selected = model
            selected.isSelected = true
            var flashing = selected
            flashing.flashes = true
            return [selected, flashing]
        }
        let long = WorkLine(
            tile: Tile(glyph: .tool(.change), state: .done),
            text: StyledText("Edited ") + StyledText("TranscriptViewController.swift", style: .noun(opens: "e1"))
                + StyledText(", ran 3 commands and searched for ") + StyledText("rowSpacing", style: .code)
                + StyledText(" across the whole package"),
            detail: "macos/TranscriptKit/Sources/TranscriptKit/Internal/TranscriptView+Layout.swift",
            exceptions: StyledText("· ") + StyledText("1 failed", style: .failure),
            meta: StyledText("+12", style: .added) + StyledText(" ") + StyledText("−3", style: .removed)
                + StyledText("  34s"))
        func custom(
            _ line: WorkLine, _ level: WorkLineRowView.Model.Level, _ action: WorkLineRowView.Model.Action,
            origin: String? = nil
        ) -> WorkLineRowView.Model {
            WorkLineRowView.Model(
                line: line, level: level, action: action, origin: origin, isSelected: false, flashes: false)
        }
        var news = long
        news.tile = Tile(glyph: .tool(.command), state: .failed)
        news.detail = nil
        news.meta = StyledText("4m")
        let bare = WorkLine(
            tile: Tile(glyph: .tool(.read), state: .running), text: StyledText("Reading A.swift"), detail: nil,
            exceptions: StyledText(), meta: StyledText())
        let fixtures = [
            ("a run", line(.line, nil)), ("a failed item", line(.item, ("b1", failedItem))),
            ("an item", line(.item, ("e1", editedItem))),
            ("a long run, collapsed", custom(long, .line, .toggle("r1", expanded: false))),
            ("a long run, expanded", custom(long, .line, .toggle("r1", expanded: true))),
            ("a long item", custom(long, .item, .open("e1"))),
            ("news with an origin", custom(news, .line, .open("n1"), origin: "b1")),
            ("a bare line", custom(bare, .line, .open("c1"))),
        ].map { RowFixture(name: $0.0, model: $0.1, sameGeometry: painted($0.1)) }
        assertContract(WorkLineRowView.self, fixtures)
    }

    func testShowMoreRowView() {
        let fixtures = [1, 85, 12_000].map {
            RowFixture(name: "\($0) hidden", model: ShowMoreRowView.Model(runID: "r1", hidden: $0))
        }
        assertContract(ShowMoreRowView.self, fixtures)
    }

    func testApprovalCardView() {
        func approval(
            _ tile: ToolKind, title: String, body: Approval.Body?, reason: String?, request: String
        ) -> Approval {
            Approval(
                id: "c1", tile: Tile(glyph: .tool(tile), state: .waiting), title: title, body: body, reason: reason,
                request: request)
        }
        let run = "Claude wants to run this command"
        let lines = (1...30).map { "let line\($0) = \($0)" }
        let wide = String(repeating: "swift build -c debug --product ccterm && ", count: 6) + "true"
        let fixtures = [
            (
                "a short command",
                approval(
                    .command, title: "Run the unit tests", body: .command("make test-unit"), reason: nil, request: run)
            ),
            (
                "a command with a reason",
                approval(
                    .command, title: "Run a command", body: .command("make test-unit FILTER=TranscriptViewTests"),
                    reason: "Needs approval: writes outside the project (build/test-dd)", request: run)
            ),
            (
                "a command that wraps",
                approval(
                    .command, title: "Run a command", body: .command(wide), reason: "Needs approval", request: run)
            ),
            (
                "a command of thirty lines",
                approval(
                    .command, title: "Run a command", body: .command(lines.joined(separator: "\n")), reason: nil,
                    request: run)
            ),
            (
                "an edit",
                approval(
                    .change, title: "Edit A.swift", body: .change(removed: ["a", "b"], added: ["c", "d", "e"]),
                    reason: nil, request: "Claude wants to make this edit")
            ),
            (
                "a long edit",
                approval(
                    .create, title: "Create B.swift", body: .newFile(lines), reason: "Needs approval: a new file",
                    request: "Claude wants to create this file")
            ),
            (
                "a tool without a body",
                approval(
                    .web, title: "Use WebFetch", body: nil, reason: nil, request: "Claude wants to use WebFetch")
            ),
        ].map { RowFixture(name: $0.0, model: $0.1) }
        assertContract(ApprovalCardView.self, fixtures)
    }

    func testNoteRowView() {
        let fixtures = [
            ("output", Note(text: "Set model to opus")),
            ("error", Note(text: "Not logged in", style: .failure)),
            ("four lines", Note(text: "Plan: Max\nWeek: 41%\nToday: 7%\nReset: Tue")),
            (
                "cut",
                Note(
                    text: "Plan: Max\nWeek: 41%",
                    link: Note.Link(title: "Show all", intent: .open("x"), isAfterDot: true))
            ),
            ("count", Note(text: "", link: Note.Link(title: "12 lines ›", intent: .open("x")))),
            ("held", Note(text: "Sent when Claude is ready")),
            ("queued", Note(text: "Queued", link: Note.Link(title: "Withdraw", intent: .withdraw("u")))),
            (
                "not sent",
                Note(
                    text: "Not sent — the session ended", style: .notSent,
                    link: Note.Link(title: "Resend", intent: .resend("u")))
            ),
            (
                "not sent, wrapping beside the mark",
                Note(
                    text: "Not sent — Claude Code refused the prompt because the organization’s policy forbids it",
                    style: .notSent, link: Note.Link(title: "Resend", intent: .resend("u")))
            ),
        ].map { RowFixture(name: $0.0, model: $0.1) }
        assertContract(NoteRowView.self, fixtures)
    }

    @MainActor
    func testAttachmentsRowView() {
        let wide = RowsSpecimen.image(number: 1, width: 400, height: 200)
        let tall = RowsSpecimen.image(number: 2, width: 100, height: 300)
        let panorama = RowsSpecimen.image(number: 3, width: 1200, height: 100)
        let fixtures = [
            ("one", [wide]), ("two", [wide, tall]), ("four wrap", [wide, tall, wide, tall]), ("panorama", [panorama]),
        ].map {
            RowFixture(
                name: $0.0,
                model: AttachmentsRowView.Model(
                    images: $0.1, titles: $0.1.map { "Image \($0.number)" }, highlighted: nil))
        }
        assertContract(AttachmentsRowView.self, fixtures)
    }

    func testDividerRowView() {
        func divider(
            _ id: String, _ kind: SessionDivider.Kind, _ label: String, summary: String? = nil, prompt: String? = nil,
            link: String? = nil
        ) -> SessionDivider {
            SessionDivider(id: id, kind: kind, summary: summary, prompt: prompt, label: label, linkTitle: link)
        }
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let fixtures = [
            divider(
                "a", .compacted(automatically: false, preTokens: 168_000, postTokens: 14_000),
                "Conversation compacted · 168k → 14k tokens", summary: "s", link: "Summary"),
            divider("b", .compacted(automatically: true, preTokens: nil, postTokens: nil), "Compacted automatically"),
            divider("c", .compacting, "Compacting…"),
            divider("d", .resumed(date), "Resumed · Sun 23:06"),
            divider("e", .pause(date), "Sun 23:06"),
            divider(
                "f", .continued(.usageLimitReset), "Continued after the usage limit reset",
                prompt: "Your usage limit has reset.", link: "Prompt"),
            divider("g", .continued(.automatic), "Continued automatically"),
            divider("h", .restarted(account: "Work", model: "Opus 4.5"), "Restarted as Work · Opus 4.5"),
        ].map { RowFixture(name: $0.id, model: $0) }
        assertContract(DividerRowView.self, fixtures)
    }

    func testInterruptionRowView() {
        assertContract(InterruptionRowView.self, [RowFixture(name: "interrupted", model: ())])
    }

    func testCaptionRowView() {
        let fixtures = [
            Caption(glyph: .subagent, text: "Explore agent"),
            Caption(glyph: .session, text: "ccterm · refactor tabs"),
            Caption(glyph: .coordinator, text: "Coordinator"),
            Caption(glyph: .plugin, text: "A plugin with a name long enough to run out of room in a narrow column"),
            Caption(glyph: .plugin, text: "Plugin “ralph-loop”", detail: "Started this turn"),
            Caption(glyph: .plugin, text: "Plugin “ralph-loop”", detail: "While Claude worked"),
            Caption(glyph: .tile(Tile(glyph: .plan, state: .done)), text: "Plan"),
            Caption(glyph: .tile(Tile(glyph: .plan, state: .waiting)), text: "Plan · Waiting for your approval"),
        ].enumerated().map { RowFixture(name: "caption \($0.offset)", model: $0.element) }
        assertContract(CaptionRowView.self, fixtures)
    }

    func testPlanDecisionRowView() {
        assertContract(PlanDecisionRowView.self, [RowFixture(name: "waiting", model: "plan-1")])
    }

    func testQuestionRowView() {
        let fixtures = [
            RowFixture(
                name: "answered", model: RowModels.one(chosen: "date-fns"),
                sameGeometry: [RowModels.one(chosen: "Moment"), RowModels.one()]),
            RowFixture(name: "long text and options", model: RowModels.long()),
            RowFixture(
                name: "several questions", model: RowModels.several(chosen: ["macOS", "iOS", "Yes"]),
                sameGeometry: [RowModels.several(chosen: ["visionOS", "No"])]),
            RowFixture(name: "waiting", model: RowModels.one(waiting: true)),
            RowFixture(name: "waiting, long", model: RowModels.long(waiting: true)),
            RowFixture(name: "waiting, several", model: RowModels.several(waiting: true)),
        ]
        assertContract(QuestionRowView.self, fixtures)
    }
}
