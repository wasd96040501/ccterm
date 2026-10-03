import AppKit
import Components
import DisplayModels

/// The transcript's `.view` rows (design/transcript, parts 1 and 4–7): the run
/// rows settled and live, background news, what sits under a command or a
/// prompt, dividers and interruptions, prompts with pictures, messages from
/// other agents, and the tools that talk to you. Each specimen is a column of
/// the real row views at the transcript's width, each at the height it declares,
/// the gaps between them the transcript's. The words of a prompt, a reply and a
/// plan are TranscriptKit's markdown rows, which the package can't draw; they
/// are left out, and what sits under or over them stays.
enum RowsSpecimen {
    /// The transcript's column (design README "Spacing"; `TranscriptKit`'s
    /// column at the editor's width), where a row view is as wide as it is.
    static let width: CGFloat = 720

    /// The gap between two entries (README "Spacing", first level), less the
    /// air a line of work already holds inside its box on either side.
    private static let entryGap: CGFloat = 14

    static func section() -> DesignPageViewController.Section {
        DesignPageViewController.Section(
            title: "Transcript rows",
            note:
                "The rows a transcript draws itself, each at the height it declares at the transcript's 720-pt "
                + "column. A line of work is a 28-pt row — tile, words, trailing meta, and a chevron or an arrow "
                + "that says what a click does — and what it discloses sits flush under it. The note under a "
                + "bubble, a divider, an interruption, a question and an approval card are rows of their own. "
                + "Between entries the gap is 14 less the air a line of work holds; an approval sits 6 under its "
                + "run, a note 3 under its bubble. Prompts, replies and plans are TranscriptKit's markdown rows and "
                + "are not shown.",
            specimens: [
                specimen("Run rows, settled — a run, what it discloses, a single call, a failure", settled),
                specimen("Run rows, live — streaming, running, and waiting for you with its approval card", live),
                specimen("Background news — a task finished, with ↖ to the call that started it", news),
                specimen("Under a bubble, dividers, interruptions — output, delivery, compaction, resume", local),
                specimen("Prompts with pasted images — thumbnails over the bubble, numbered when several", prompts),
                specimen("Messages from other agents — captions, and the talk that opens beside", voices),
                specimen("Tools that talk to you — questions, approvals, plan decisions", talk),
            ])
    }

    private static func specimen(_ title: String, _ rows: [Row]) -> DesignPageViewController.Specimen {
        let column = RowColumn(rows)
        return .init(title: title, view: RowColumnHost(column, size: column.size), height: nil)
    }

    // MARK: - Rows

    /// One row of a specimen: its view, the height it declares, and what sits above it.
    struct Row {
        enum Above {
            /// The gap between entries, less each side's air.
            case entry
            /// A fixed gap: what a line discloses (0), a card (6), a note (3).
            case fixed(CGFloat)
        }
        var view: NSView
        var height: CGFloat
        var air: CGFloat
        var above: Above
    }

    private static func row<V: PageRowView>(
        _ type: V.Type, _ model: V.Model, air: CGFloat = 0, above: Row.Above = .entry
    ) -> Row {
        let view = V()
        view.configure(with: model)
        return Row(view: view, height: V.height(for: model, width: width), air: air, above: above)
    }

    private static func work(
        _ line: WorkLine, _ level: WorkLineRowView.Model.Level = .line,
        _ action: WorkLineRowView.Model.Action = .none, origin: String? = nil, selected: Bool = false
    ) -> Row {
        row(
            WorkLineRowView.self,
            .init(line: line, level: level, action: action, origin: origin, isSelected: selected, flashes: false),
            air: WorkLineRowView.air, above: level == .item ? .fixed(0) : .entry)
    }

    private static func more(_ hidden: Int) -> Row {
        row(ShowMoreRowView.self, .init(runID: "r", hidden: hidden), air: WorkLineRowView.air, above: .fixed(0))
    }

    private static func card(_ approval: Approval) -> Row {
        row(ApprovalCardView.self, approval, above: .fixed(6))
    }

    private static func note(_ note: Note, under: Bool = true) -> Row {
        row(NoteRowView.self, note, above: under ? .fixed(3) : .entry)
    }

    // MARK: - Words

    private static func tile(_ kind: ToolKind, _ state: Tile.State = .done) -> Tile {
        Tile(glyph: .tool(kind), state: state)
    }

    private static func line(
        _ kind: ToolKind, _ state: Tile.State = .done, text: StyledText, detail: String? = nil,
        words: Bool = false, exceptions: StyledText = StyledText(), meta: StyledText = StyledText()
    ) -> WorkLine {
        WorkLine(
            tile: tile(kind, state), text: text, detail: detail, detailIsWords: words, exceptions: exceptions,
            meta: meta)
    }

    private static func file(_ name: String) -> StyledText { StyledText(name, style: .noun(opens: name)) }

    private static var stat: StyledText {
        StyledText("+12", style: .added) + StyledText(" ") + StyledText("−3", style: .removed) + StyledText("  34s")
    }

    private static let failedOne = StyledText("· ") + StyledText("1 failed", style: .failure)

    // MARK: - Part 1: the run row

    private static var settled: [Row] {
        let run = line(
            .change, text: StyledText("Edited ") + file("TranscriptView.swift") + StyledText(", ran 3 commands"),
            exceptions: failedOne, meta: stat)
        let edited = line(
            .change, text: StyledText("TranscriptView.swift", style: .noun(opens: nil)),
            detail: "macos/TranscriptKit/Sources/TranscriptKit/Internal/TranscriptView+Layout.swift",
            meta: StyledText.diffStat(added: 4, removed: 2))
        let failed = line(
            .command, .failed, text: StyledText("Run the unit tests"), detail: "make test-unit FILTER=Tran…",
            meta: StyledText("14s"))
        let built = line(
            .command, text: StyledText("Build the package"), detail: "swift build -c debug --product ccterm",
            meta: StyledText("6s"))
        let long = line(
            .change,
            text: StyledText("Edited ") + file("TranscriptViewController.swift")
                + StyledText(", ran 3 commands and searched for ") + StyledText("rowSpacing", style: .code)
                + StyledText(" across the whole package"),
            detail: "macos/TranscriptKit/Sources/TranscriptKit/Internal/TranscriptView+Layout.swift",
            exceptions: failedOne, meta: stat)
        return [
            work(run, .line, .toggle("r1", expanded: true)),
            work(edited, .item, .open("e1")), work(failed, .item, .open("b2")),
            work(built, .item, .open("b1")), more(85),
            work(built, .line, .open("b1")),
            work(line(.change, text: StyledText("Edited 3 files, ran 2 commands"), meta: stat), selected: true),
            work(long, .line, .toggle("r2", expanded: false)),
        ]
    }

    private static var live: [Row] {
        let reading = line(
            .read, .running, text: StyledText("Reading ") + file("PageBuilder.swift"), meta: StyledText("12s"))
        let preparing = line(
            .change, .preparing, text: StyledText("Editing ") + file("TileView.swift"))
        let waiting = line(.command, .waiting, text: StyledText("Waiting for your approval"))
        let approval = Approval(
            id: "c1", tile: Tile(glyph: .tool(.command), state: .waiting), title: "Run the unit tests",
            body: .command("make test-unit FILTER=TranscriptViewTests"),
            reason: "Needs approval: writes outside the project (build/test-dd)",
            request: "Claude wants to run this command")
        return [
            work(reading, .item, .open("r1")), work(preparing, .line, .open("e1")),
            work(waiting, .line, .toggle("r", expanded: false)), card(approval),
        ]
    }

    // MARK: - Part 4: background news

    private static var news: [Row] {
        let finished = line(
            .command,
            text: StyledText("Background command ") + StyledText("“Run tests”", style: .code)
                + StyledText(" finished"), meta: StyledText("4m"))
        let failed = line(
            .command, .failed,
            text: StyledText("Background command ") + StyledText("“Build”", style: .code) + StyledText(" failed"),
            meta: StyledText("2m"))
        return [
            work(finished, .line, .open("n1"), origin: "b1"),
            work(failed, .line, .toggle("n2", expanded: true)),
            work(finished, .item, .open("n3"), origin: "b1"),
            work(failed, .item, .open("n4"), origin: "b2"),
        ]
    }

    // MARK: - Part 5: local commands, dividers, interruptions

    private static var local: [Row] {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        func divider(_ id: String, _ kind: SessionDivider.Kind, label: String, link: String? = nil) -> Row {
            row(
                DividerRowView.self,
                SessionDivider(id: id, kind: kind, summary: nil, prompt: nil, label: label, linkTitle: link))
        }
        return [
            note(Note(text: "Set model to opus")),
            note(Note(text: "Unknown effort level: maximum", style: .failure), under: false),
            note(
                Note(
                    text: "61k / 200k tokens (31%)",
                    link: Note.Link(title: "Show all", intent: .open("0"), isAfterDot: true)), under: false),
            note(Note(text: "", link: Note.Link(title: "4 lines ›", intent: .open("0"))), under: false),
            row(InterruptionRowView.self, ()),
            divider(
                "a", .compacted(automatically: false, preTokens: 168_000, postTokens: 14_000),
                label: "Conversation compacted · 168k → 14k tokens", link: "Summary"),
            divider("b", .compacting, label: "Compacting…"),
            divider("c", .resumed(date), label: "Resumed · Sun 23:06"),
            divider("d", .pause(date), label: "Sun 23:06"),
            divider(
                "e", .restarted(account: "Work", model: "Opus 4.5"),
                label: "Restarted as Work · Opus 4.5"),
        ]
    }

    // MARK: - Part 5: prompts with images

    /// A picture to paste into a prompt: a PNG with a gradient and a grid, so a
    /// thumbnail's crop can be told by eye.
    static func image(number: Int, width: Int, height: Int, hue: CGFloat = 0.58) -> PromptImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        NSGradient(
            colors: [
                NSColor(hue: hue, saturation: 0.5, brightness: 0.95, alpha: 1),
                NSColor(hue: hue + 0.1, saturation: 0.7, brightness: 0.7, alpha: 1),
            ])?.draw(in: bounds, angle: 315)
        NSColor.white.withAlphaComponent(0.35).setStroke()
        let grid = NSBezierPath()
        let step = CGFloat(max(width, height)) / 8
        var x = step
        while x < CGFloat(width) {
            grid.move(to: NSPoint(x: x, y: 0))
            grid.line(to: NSPoint(x: x, y: CGFloat(height)))
            x += step
        }
        var y = step
        while y < CGFloat(height) {
            grid.move(to: NSPoint(x: 0, y: y))
            grid.line(to: NSPoint(x: CGFloat(width), y: y))
            y += step
        }
        grid.lineWidth = 2
        grid.stroke()
        NSGraphicsContext.restoreGraphicsState()
        return PromptImage(
            id: PromptImage.id(entryID: "p", number: number), number: number, mediaType: "image/png",
            data: rep.representation(using: .png, properties: [:])!, width: width, height: height)
    }

    private static func pictures(_ images: [PromptImage]) -> Row {
        row(
            AttachmentsRowView.self,
            .init(images: images, titles: images.map { "Image \($0.number)" }, highlighted: nil))
    }

    private static var prompts: [Row] {
        [
            pictures([image(number: 1, width: 1440, height: 900)]),
            pictures([
                image(number: 2, width: 1200, height: 760, hue: 0.65),
                image(number: 3, width: 900, height: 1100, hue: 0.1),
            ]),
            note(Note(text: "Queued", link: Note.Link(title: "Withdraw", intent: .withdraw("u")))),
            note(
                Note(
                    text: "Not sent — the session ended", style: .notSent,
                    link: Note.Link(title: "Resend", intent: .resend("u"))), under: false),
        ]
    }

    // MARK: - Parts 6 and 7: other agents, talking out, talking to you

    private static var voices: [Row] {
        func caption(_ glyph: Caption.Glyph, _ text: String, _ detail: String? = nil) -> Row {
            row(CaptionRowView.self, Caption(glyph: glyph, text: text, detail: detail))
        }
        let advised = line(
            .advisor, text: StyledText("Asked the advisor"),
            detail: "Check the narrow split before you change the default: at 320 pt the run rows wrap.", words: true)
        let messaged = line(
            .message, text: StyledText("Messaged ") + StyledText("team-lead", style: .noun(opens: nil)),
            detail: "Row gap is public; tests pass", words: true)
        let refused = line(
            .advisor, text: StyledText("Asked the advisor"), detail: "Declined to advise", words: true)
        let overloaded = line(
            .advisor, .failed, text: StyledText("Asked the advisor"), detail: "Overloaded — try again shortly",
            words: true)
        return [
            caption(.plugin, "Plugin “taskcut”", "Started this turn"),
            caption(.plugin, "Plugin “ralph-loop”", "While Claude worked"),
            caption(.subagent, "Explore agent"), caption(.session, "ccterm · refactor tabs"),
            caption(.coordinator, "Coordinator"),
            work(advised, .line, .open("v")), work(messaged, .line, .open("m")),
            work(refused), work(overloaded),
        ]
    }

    private static var talk: [Row] {
        func item(
            _ header: String, _ text: String, several: Bool = false, _ options: [Question.Item.Option]
        ) -> Question.Item {
            Question.Item(header: header, text: text, options: options, allowsSeveral: several)
        }
        func option(_ label: String, _ detail: String, chosen: Bool = false) -> Question.Item.Option {
            Question.Item.Option(label: label, detail: detail, isChosen: chosen)
        }
        let gap = item(
            "Row gap", "What should the default gap between rows be?",
            [
                option("14 pt", "Today's value"), option("12 pt", "Same as between paragraphs"),
                option("16 pt", "Roomier"),
            ])
        let scope = item(
            "Scope",
            "The gap is hard-coded in two places besides the view. Which of them should read the new property, and which should keep their own value?",
            [
                option(
                    "Both read rowSpacing",
                    "TranscriptView and EditorArea always agree, and a change in one place moves both. The tests that pin 14 pt need updating."
                ),
                option(
                    "Only TranscriptView",
                    "EditorArea keeps its own 14 pt for now; the two can drift, which is fine while it has no transcript of its own."
                ),
                option(
                    "Neither — a theme value",
                    "Move the gap into the theme, which both read. Most work, and the theme has no spacing values yet."),
            ])
        let checks = item(
            "Checks", "What should run before the PR?", several: true,
            [
                option("Unit tests", "make test-unit and make test-kit"),
                option("Snapshot of a narrow split", "TranscriptSnapshotTests at 320 pt"),
                option("The demo app", "make demo-kit, to look at it by hand"),
            ])
        func question(
            _ id: String, _ items: [Question.Item], waiting: Bool = false, outcome: String? = nil,
            talkedOver: Bool = false
        ) -> Row {
            row(
                QuestionRowView.self,
                Question(id: id, items: items, isWaiting: waiting, outcome: outcome, isTalkedOver: talkedOver))
        }
        var answered = gap
        answered = Question.Item(
            header: gap.header, text: gap.text,
            options: gap.options + [option("13 pt — between the two", "Other", chosen: true)], allowsSeveral: false)
        let command = Approval(
            id: "a1", tile: Tile(glyph: .tool(.command), state: .waiting), title: "Run the unit tests",
            body: .command("make test-unit FILTER=TranscriptViewTests"), reason: nil,
            request: "Claude wants to run this command")
        let edit = Approval(
            id: "a2", tile: Tile(glyph: .tool(.change), state: .waiting), title: "Edit TranscriptView.swift",
            body: .change(
                removed: ["var rowSpacing = 14", "var other = 1"],
                added: ["public var rowSpacing: CGFloat = 14 {", "    didSet { apply() }", "}"]), reason: nil,
            request: "Claude wants to make this edit")
        let create = Approval(
            id: "a3", tile: Tile(glyph: .tool(.create), state: .waiting), title: "Create B.swift",
            body: .newFile(["import Foundation", "", "struct B {", "    var value = 1", "}"]),
            reason: "Needs approval: a new file", request: "Claude wants to create this file")
        let bare = Approval(
            id: "a4", tile: Tile(glyph: .tool(.web), state: .waiting), title: "Use WebFetch", body: nil, reason: nil,
            request: "Claude wants to use WebFetch")
        return [
            question("q1", [gap], waiting: true), question("q2", [scope, checks], waiting: true),
            question("q3", [answered]),
            question(
                "q4", [gap], outcome: "Not answered — talked over in the conversation", talkedOver: true),
            row(PlanDecisionRowView.self, "plan-1"),
            card(command), card(edit), card(create), card(bare),
        ]
    }
}

/// The rows of a specimen, one under another, by frame at the transcript's width.
private final class RowColumn: NSView {
    let size: NSSize

    init(_ rows: [RowsSpecimen.Row]) {
        var y: CGFloat = 0
        var previous: RowsSpecimen.Row?
        var frames: [(NSView, NSRect)] = []
        for row in rows {
            if let previous {
                switch row.above {
                case .entry: y += 14 - previous.air - row.air
                case .fixed(let gap): y += gap
                }
            }
            frames.append((row.view, NSRect(x: 0, y: y, width: RowsSpecimen.width, height: row.height)))
            y += row.height
            previous = row
        }
        size = NSSize(width: RowsSpecimen.width, height: y)
        super.init(frame: NSRect(origin: .zero, size: size))
        for (view, frame) in frames {
            view.frame = frame
            addSubview(view)
        }
    }

    override var isFlipped: Bool { true }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

/// A host wider than the page's column, scaled down whole: the content keeps
/// its own coordinates (`bounds`), and the holder it sits in is as wide as the
/// card allows, up to the content's own width, centred.
private final class RowColumnHost: NSView {
    private let holder = Holder()

    init(_ content: NSView, size: NSSize) {
        super.init(frame: .zero)
        holder.setContent(content, size: size)
        holder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(holder)
        let wide = holder.widthAnchor.constraint(equalToConstant: size.width)
        wide.priority = NSLayoutConstraint.Priority(10)
        NSLayoutConstraint.activate([
            holder.topAnchor.constraint(equalTo: topAnchor),
            holder.bottomAnchor.constraint(equalTo: bottomAnchor),
            holder.centerXAnchor.constraint(equalTo: centerXAnchor),
            holder.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            holder.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            wide, holder.widthAnchor.constraint(lessThanOrEqualToConstant: size.width),
            // 24 above and below, at the scale the width gives.
            holder.heightAnchor.constraint(
                equalTo: holder.widthAnchor, multiplier: (size.height + 48) / size.width),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private final class Holder: NSView {
        private var content: NSView?
        private var size = NSSize.zero

        override var isFlipped: Bool { true }

        func setContent(_ content: NSView, size: NSSize) {
            self.content = content
            self.size = size
            addSubview(content)
        }

        override func layout() {
            super.layout()
            guard let content, size.width > 0 else { return }
            let scale = min(1, bounds.width / size.width)
            content.frame = NSRect(x: 0, y: 24 * scale, width: size.width * scale, height: size.height * scale)
            content.bounds = NSRect(origin: .zero, size: size)
        }
    }
}
