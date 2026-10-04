import AppKit
import Components
import DisplayModels

/// What a call opens beside the transcript (design/transcript, *2 · The command
/// document* and *3 · File documents*): the jump bar over a body, and the
/// approval bar between them while the call waits. Each document sits in the
/// sheet's `.docframe` — a caption over a 380-pt document — and the frames flow
/// as the sheet's `.docs` grid does: as many columns as fit at least 420 wide,
/// sharing the column, 16 apart.
enum DocumentsSpecimen {
    static func section() -> DesignPageViewController.Section {
        DesignPageViewController.Section(
            title: "Documents",
            note:
                "A document is a page beside the transcript, under a 28-pt jump bar: the kind's tile, the path, the "
                + "stat, and Show in Transcript. A command reads top to bottom — what was meant, what ran in its card, "
                + "what came out, stdout and stderr as one stream — and only facts that are true are on it. A file "
                + "is Xcode's source editor, read-only: a change as one diff with folds and the characters that "
                + "changed, a new file under one green bar, a read with the file map on the right. While its call "
                + "waits, an approval bar sits under the jump bar with the same buttons and keys as the card.",
            specimens: [
                .init(
                    title: "Command documents — failed, warnings, a note, running, waiting, background, too long",
                    view: DocumentGrid(Self.commands()), height: nil),
                .init(
                    title: "File documents — a change, a new file, a read, a change that failed, one waiting, one gone",
                    view: DocumentGrid(Self.files()), height: nil),
            ])
    }

    // MARK: - Commands

    private static let log = """
        Test Suite 'TranscriptViewTests' started
        Test Case 'testRows' \u{1B}[1;32mpassed\u{1B}[0m (0.02 seconds)
        Test Case 'testSpacing' \u{1B}[31mfailed\u{1B}[0m (0.01 seconds)
        TranscriptViewTests.swift:41:5: error: 'rowSpacing' is inaccessible due to 'private' protection level
        ** TEST FAILED **
        """

    private static func command(
        _ caption: String, _ summary: CommandSummary, state: Tile.State, approval: Approval? = nil
    ) -> DocumentFrame.Content {
        DocumentFrame.Content(
            caption: caption,
            header: DocumentHeader(
                tile: Tile(glyph: .tool(.command), state: state), crumbs: [summary.heading],
                title: summary.heading),
            approval: approval, body: CommandDocumentViewController(summary))
    }

    private static func commands() -> [DocumentFrame.Content] {
        let failed = StyledText("Failed", style: .failure) + StyledText(" · exit 65 · 48s")
        let waiting = Approval(
            id: "c1", tile: Tile(glyph: .tool(.command), state: .waiting), title: "Remove the build cache",
            body: .command("rm -rf macos/build/test-dd"), reason: "rm -rf needs approval: it deletes files.",
            request: "Claude wants to run this command")
        return [
            command(
                "Failed",
                CommandSummary(
                    heading: "Run the unit tests", status: failed,
                    command: "cd ~/dev/ccterm && make test-unit FILTER=TranscriptViewTests", stdout: log,
                    stderr: "xcodebuild: error: Failed to build workspace"), state: .failed),
            command(
                "Output with warnings — stdout and stderr are one stream, in the order printed",
                CommandSummary(
                    heading: "Build the package", status: StyledText("6s"),
                    command: "cd macos/TranscriptKit && swift build",
                    stdout: """
                        Building for debugging...
                        TranscriptView.swift:88:9: warning: variable 'count' was never mutated
                        [4/9] Compiling TranscriptKit TranscriptView.swift
                        Build complete! (5.87s)
                        """), state: .done),
            command(
                "Succeeded · a note on the exit code · sandbox off",
                CommandSummary(
                    heading: "Find the old constant", status: StyledText("0.4s"), warning: "Sandbox off",
                    command: "grep -rn 'Self.rowSpacing' macos",
                    note: "No matches found (exit code 1 means grep found nothing).", emptyNote: "No output"),
                state: .done),
            command(
                "Running — output arrives with the result",
                CommandSummary(
                    heading: "Run the TranscriptView tests", status: StyledText("Running"),
                    command: "cd ~/dev/ccterm && make test-unit FILTER=TranscriptViewTests",
                    emptyNote: "Output appears when the command finishes.", isRunning: true), state: .running),
            command(
                "Waiting for you",
                CommandSummary(
                    heading: "Remove the build cache", status: StyledText("Waiting for your approval"),
                    command: "rm -rf macos/build/test-dd", hasOutputArea: false), state: .waiting,
                approval: waiting),
            command(
                "In background — following its output file",
                CommandSummary(
                    heading: "Build the demo app", status: StyledText("Running in background"),
                    command: "make demo-kit",
                    stdout: """
                        Building for production...
                        [131/214] Compiling TranscriptKit RowCache.swift
                        [132/214] Compiling TranscriptKit RowCacheEntry.swift
                        """), state: .background),
            command(
                "Output too long to keep",
                CommandSummary(
                    heading: "Dump the unified log", status: StyledText("4s"),
                    command: "make logs LEVEL=debug | head -2000",
                    stdout: """
                        2026-09-29 11:40:02.114 ccterm[5012] <Info> TranscriptViewController: load started
                        2026-09-29 11:40:02.120 ccterm[5012] <Debug> RowCache: warm 30 rows
                        …
                        """, persistedPath: "~/.claude/tool-results/bp7e6ce4y.txt",
                    persistedNote: "Output was too long to keep here. The full output is in"), state: .done),
        ]
    }

    // MARK: - Files

    private static let path = "macos/TranscriptKit/Sources/TranscriptKit/TranscriptView.swift"

    private static let swift = """
        import AppKit

        final class TranscriptView: NSView {
            var rowSpacing: CGFloat = 14 // gap between rows
            func reload() {
                let count = rows.count
                guard count > 0 else { return }
                print("rows: \\(count)")
            }
        }
        """

    private static func lines(_ text: String, from first: Int = 1) -> [SourceLines.Line] {
        text.components(separatedBy: "\n").enumerated().map {
            SourceLines.Line(kind: .context, number: first + $0.offset, text: $0.element)
        }
    }

    private static func file(
        _ caption: String, _ source: SourceLines, mode: SourceDocumentViewController.Mode, glyph: ToolKind,
        state: Tile.State = .done, stat: StyledText = StyledText(), approval: Approval? = nil
    ) -> DocumentFrame.Content {
        let crumbs = ["ccterm"] + path.split(separator: "/").map(String.init)
        return DocumentFrame.Content(
            caption: caption,
            header: DocumentHeader(
                tile: Tile(glyph: .tool(glyph), state: state), crumbs: crumbs, stat: stat, title: "TranscriptView.swift"
            ),
            approval: approval, body: SourceDocumentViewController(source, mode: mode, path: path))
    }

    private static func files() -> [DocumentFrame.Content] {
        var change = SourceLines(
            lines: [
                .init(kind: .fold, text: "12 lines"),
                .init(kind: .context, number: 13, text: "final class TranscriptView: NSView {"),
                .init(kind: .removed, text: "    private var rowSpacing: CGFloat = 4 // gap between rows"),
                .init(kind: .added, number: 14, text: "    var rowSpacing: CGFloat = 6 // gap between rows"),
                .init(kind: .context, number: 15, text: "    func reload() {"),
                .init(kind: .context, number: 16, text: "        let count = rows.count"),
                .init(kind: .fold, text: "Lines 17–39"),
                .init(kind: .context, number: 40, text: "}"),
                .init(kind: .added, number: 41, text: "// done"),
                .init(kind: .fold, text: "39 lines"),
            ])
        change.markChangedCharacters()
        let created = SourceLines(lines: lines(swift))
        let read = SourceLines(
            lines: lines(swift, from: 40), slice: .init(first: 40, last: 49, total: 880))
        var failed = SourceLines(
            lines: [
                .init(kind: .removed, text: "let a = 1"), .init(kind: .added, text: "let a = 2"),
                .init(kind: .added, text: "let b = 3"),
            ], notes: [.init(style: .error, text: "String to replace not found in file.")])
        failed.markChangedCharacters()
        var proposed = SourceLines(
            lines: [
                .init(kind: .removed, text: "    private var rowSpacing: CGFloat = 4"),
                .init(kind: .added, text: "    var rowSpacing: CGFloat = 14"),
            ])
        proposed.markChangedCharacters()
        let waiting = Approval(
            id: "c2", tile: Tile(glyph: .tool(.change), state: .waiting), title: "Edit TranscriptView.swift",
            body: .change(
                removed: ["    private var rowSpacing: CGFloat = 4"], added: ["    var rowSpacing: CGFloat = 14"]),
            reason: "Edits need approval in Default mode.", request: "Claude wants to edit this file")
        return [
            file(
                "Change — in place, with folds and the characters that changed", change, mode: .change,
                glyph: .change, stat: .diffStat(added: 2, removed: 1)),
            file(
                "New file — no wash; one green bar says “all new”", created, mode: .newFile, glyph: .create,
                stat: StyledText("New · 10 lines")),
            file(
                "Read — the file map on the right: what it saw, and where", read, mode: .read, glyph: .read,
                stat: StyledText("Lines 40–49 of 880")),
            file(
                "Change that failed — the proposed diff under the error", failed, mode: .change, glyph: .change,
                state: .failed, stat: .diffStat(added: 2, removed: 1)),
            file(
                "Change waiting for you — the approval bar under the jump bar", proposed, mode: .change,
                glyph: .change, state: .waiting, stat: .diffStat(added: 1, removed: 1), approval: waiting),
            DocumentFrame.Content(
                caption: "Gone — a document whose call is no longer in the transcript",
                header: DocumentHeader(
                    tile: Tile(glyph: .tool(.read), state: .done),
                    crumbs: ["ccterm"] + path.split(separator: "/").map(String.init),
                    title: "TranscriptView.swift"),
                approval: nil,
                body: DocumentNoteViewController("This document is no longer in the transcript.")),
        ]
    }
}

// MARK: - The frames

/// A document as the sheet frames it: a caption bar over the document, rounded,
/// under a hairline: the caption, then a document 380 tall with its jump bar.
private final class DocumentFrame: NSView {
    struct Content {
        var caption: String
        var header: DocumentHeader
        var approval: Approval?
        var body: NSViewController
    }

    static let documentHeight: CGFloat = 380
    static let captionHeight: CGFloat = 33

    /// What owns the body, kept as long as the frame is.
    private let body: NSViewController

    init(_ content: Content) {
        body = content.body
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        let caption = CaptionBar(content.caption)
        let jumpBar = JumpBarView()
        jumpBar.configure(with: content.header)
        var bars: [NSView] = [caption, jumpBar]
        if let approval = content.approval {
            let bar = ApprovalBarView()
            bar.configure(with: approval)
            bars.append(bar)
        }
        let stack = NSStackView(views: bars)
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        body.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body.view)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            caption.widthAnchor.constraint(equalTo: stack.widthAnchor),
            jumpBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            jumpBar.heightAnchor.constraint(equalToConstant: JumpBarView.height),
            body.view.topAnchor.constraint(equalTo: stack.bottomAnchor),
            body.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        if let bar = bars.dropFirst(2).first { bar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.borderWidth = 0.5
        }
    }
}

/// `.docframe > .cap`: 12-pt secondary words, the bold part before ` — ` in
/// label colour, 14 in, a hairline under, the chrome's tone.
private final class CaptionBar: NSView {
    private let separator = CALayer()

    init(_ caption: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(separator)
        let parts = caption.components(separatedBy: " — ")
        let text = NSMutableAttributedString(
            string: parts[0],
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor])
        if parts.count > 1 {
            text.append(
                NSAttributedString(
                    string: " — " + parts.dropFirst().joined(separator: " — "),
                    attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = text
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: DocumentFrame.captionHeight),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.underPageBackgroundColor.withAlphaComponent(0.35).cgColor
            separator.backgroundColor = NSColor.separatorColor.cgColor
        }
    }

    override func layout() {
        super.layout()
        separator.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 0.5)
    }
}

/// The sheet's `.docs`: `repeat(auto-fit, minmax(420px, 1fr))`, 16 apart — as
/// many columns as fit, each sharing the width, a frame to a row's cell. The
/// frames take the width the column gives them, as documents do.
private final class DocumentGrid: NSView {
    private static let minimumWidth: CGFloat = 420
    private static let gap: CGFloat = 16
    private static let padding: CGFloat = 16

    private let frames: [DocumentFrame]
    private var height: NSLayoutConstraint

    init(_ documents: [DocumentFrame.Content]) {
        frames = documents.map(DocumentFrame.init)
        height = NSLayoutConstraint()
        super.init(frame: .zero)
        frames.forEach(addSubview)
        height = heightAnchor.constraint(equalToConstant: 0)
        height.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        let available = bounds.width - 2 * Self.padding
        let columns = max(1, Int(((available + Self.gap) / (Self.minimumWidth + Self.gap)).rounded(.down)))
        let width = ((available - Self.gap * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
        let cell = DocumentFrame.captionHeight + DocumentFrame.documentHeight
        for (index, frame) in frames.enumerated() {
            let column = index % columns
            let row = index / columns
            frame.frame = NSRect(
                x: Self.padding + CGFloat(column) * (width + Self.gap),
                y: Self.padding + CGFloat(row) * (cell + Self.gap), width: width, height: cell)
        }
        let rows = (frames.count + columns - 1) / columns
        let total = 2 * Self.padding + CGFloat(rows) * cell + CGFloat(max(rows - 1, 0)) * Self.gap
        if height.constant != total { height.constant = total }
        super.layout()
    }
}
