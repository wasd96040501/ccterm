import AppKit
import Components
import XCTest

@testable import ccterm

/// Numbered lines as a change, a new file, a read and command output, in light
/// and dark (design/transcript/03-file.md, 02-command.md). Review only —
/// `make test-unit FILTER=NumberedLinesViewSnapshotTests`, then open
/// `/tmp/ccterm-screenshots/NumberedLinesView.png`.
@MainActor
final class NumberedLinesViewSnapshotTests: XCTestCase {
    private typealias Line = NumberedLinesView.Line

    private static let swift = """
        import AppKit

        final class TranscriptView: NSView {
            private var rowSpacing: CGFloat = 4 // gap between rows
            func reload() {
                let count = rows.count
                guard count > 0 else { return }
                print("rows: \\(count)")
            }
        }
        """

    private func sourceLines(path: String = "A.swift", from lines: [String], start: Int = 1) -> [Line] {
        lines.enumerated().map {
            Line(
                number: start + $0.offset, text: $0.element,
                spans: SyntaxHighlighter.spans(in: $0.element, path: path))
        }
    }

    private var changeLines: [Line] {
        let old = "    private var rowSpacing: CGFloat = 4 // gap between rows"
        let new = "    var rowSpacing: CGFloat = 6 // gap between rows"
        let lines: [Line] = [
            Line(kind: .fold, text: "12 lines"),
            Line(number: 13, text: "final class TranscriptView: NSView {"),
            Line(kind: .removed, text: old, changed: [4..<12, 32..<33]),
            Line(kind: .added, number: 14, text: new, changed: [32..<33]),
            Line(number: 15, text: "    func reload() {"),
            Line(number: 16, text: "        let count = rows.count"),
            Line(kind: .fold, text: "Lines 17–39"),
            Line(number: 40, text: "}"),
        ]
        return lines.map { line in
            var line = line
            if line.kind != .fold { line.spans = SyntaxHighlighter.spans(in: line.text, path: "A.swift") }
            return line
        }
    }

    private func controller(_ content: NumberedLinesView.Content, header: NSView? = nil) -> NSViewController {
        let view = NumberedLinesView()
        view.header = header
        view.configure(with: content)
        let controller = NSViewController()
        controller.view = view
        return controller
    }

    private func header() -> NSView {
        let box = NSView()
        let label = NSTextField(wrappingLabelWithString: "Run the unit tests\nFailed · exit 65 · 48s")
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 20),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -24),
        ])
        return box
    }

    func testEveryKindOfLines() {
        let size = CGSize(width: 520, height: 260)
        let source = Self.swift.components(separatedBy: "\n")
        let states: [(String, () -> NSViewController)] = [
            (
                "change",
                { self.controller(.init(lines: self.changeLines, style: .source, bar: .hunks)) }
            ),
            (
                "new",
                {
                    self.controller(.init(lines: self.sourceLines(from: source), style: .source, bar: .wholeFile))
                }
            ),
            (
                "read",
                {
                    self.controller(
                        .init(
                            lines: self.sourceLines(from: source, start: 40), style: .source,
                            fileMap: .init(start: 40.0 / 880, length: 9.0 / 880)))
                }
            ),
            (
                "output",
                {
                    let ansi = ANSIText(
                        "Test Suite started\n\u{1B}[1;32mPASS\u{1B}[0m one\n\u{1B}[31mfail\u{1B}[0m two\nA.swift:41:5: error: 'rowSpacing' is inaccessible due to 'private' protection level that goes on and on and on for a long while to wrap\n** TEST FAILED **"
                    )
                    var lines = ansi.lines.enumerated().map {
                        Line(
                            number: $0.offset + 1, text: $0.element.text, spans: $0.element.spans,
                            numberIsError: CommandSummary.isErrorLine($0.element.text))
                    }
                    lines.append(Line(kind: .divider, text: "stderr"))
                    lines.append(
                        Line(number: 1, text: "xcodebuild: error: Failed to build workspace", numberIsError: true))
                    return self.controller(.init(lines: lines, style: .output), header: self.header())
                }
            ),
        ]
        for (name, make) in states {
            let sheet = ViewSnapshot.renderLightAndDark(make, size: size, name: name)
            let url = ViewSnapshot.writePNG(sheet, name: "NumberedLinesView-\(name)")
            let attachment = XCTAttachment(contentsOfFile: url)
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
