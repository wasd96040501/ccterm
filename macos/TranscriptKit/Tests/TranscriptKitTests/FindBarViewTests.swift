import AppKit
import XCTest

@testable import TranscriptKitDemo

/// The find bar in a `TestWindow`, typed into through its field editor the way
/// the keyboard reaches it, and asserted on what it told its delegate.
@MainActor
final class FindBarViewTests: XCTestCase {

    func testTypingReportsEveryChange() throws {
        let mounted = mount()
        defer { mounted.window.close() }

        let editor = try beginTyping(mounted)
        editor.insertText("cl", replacementRange: editor.selectedRange())
        editor.insertText("a", replacementRange: editor.selectedRange())

        XCTAssertEqual(mounted.recorder.queries, ["cl", "cla"])
        XCTAssertFalse(mounted.bar.clearButton.isHidden, "no clear button beside a query")
    }

    func testReturnFindsTheNextMatchAndEscapeIsDone() throws {
        let mounted = mount()
        defer { mounted.window.close() }

        let editor = try beginTyping(mounted)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))

        XCTAssertEqual(mounted.recorder.actions, [.nextMatch, .hideFindInterface])
    }

    func testTheArrowsAndDoneReportTheirActions() throws {
        let mounted = mount()
        defer { mounted.window.close() }
        let bar = mounted.bar
        bar.searchString = "claude"
        bar.numberOfMatches = 3
        XCTAssertTrue(bar.navigation.isEnabled, "premise: there are matches to step through")

        press(segment: 1, of: bar.navigation)
        press(segment: 0, of: bar.navigation)
        bar.doneButton.performClick(nil)

        XCTAssertEqual(
            mounted.recorder.actions, [.nextMatch, .previousMatch, .hideFindInterface])
    }

    func testTheCountSaysHowManyAndTheArrowsFollowIt() throws {
        let mounted = mount()
        defer { mounted.window.close() }
        let bar = mounted.bar
        bar.searchString = "claude"

        XCTAssertTrue(bar.countLabel.isHidden, "a count before any was given")
        bar.numberOfMatches = 3
        XCTAssertFalse(bar.countLabel.isHidden)
        XCTAssertEqual(bar.countLabel.stringValue, String(localized: "\(3) matches", bundle: .module))
        bar.numberOfMatches = 1
        XCTAssertEqual(bar.countLabel.stringValue, String(localized: "1 match", bundle: .module))
        bar.numberOfMatches = 0
        XCTAssertEqual(bar.countLabel.stringValue, String(localized: "No matches", bundle: .module))
        XCTAssertFalse(bar.navigation.isEnabled, "arrows with nothing to step to")
        bar.numberOfMatches = nil
        XCTAssertTrue(bar.countLabel.isHidden)
    }

    func testClearingEmptiesTheQueryAndSaysSo() throws {
        let mounted = mount()
        defer { mounted.window.close() }
        let bar = mounted.bar
        bar.searchString = "claude"
        bar.numberOfMatches = 3

        bar.clearButton.performClick(nil)

        XCTAssertEqual(bar.searchString, "")
        XCTAssertEqual(mounted.recorder.queries, [""])
        XCTAssertTrue(bar.clearButton.isHidden)
        XCTAssertTrue(bar.countLabel.isHidden, "a count left beside an empty field")
    }

    /// ⌘F with the caret already in the query selects it, so typing replaces it.
    /// Already in it on purpose: a field taking the focus selects its text on its
    /// own, so only this case says anything about the bar.
    func testBeginningToEditSelectsTheQuery() throws {
        let mounted = mount()
        defer { mounted.window.close() }
        let editor = try beginTyping(mounted)
        editor.insertText("claude", replacementRange: editor.selectedRange())
        XCTAssertEqual(
            editor.selectedRange(), NSRange(location: 6, length: 0),
            "premise: the caret is after the query")

        mounted.bar.beginEditing()

        XCTAssertIdentical(mounted.window.firstResponder, editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 6))
    }

    /// The query gets the width; the count, the arrows and Done keep theirs.
    func testTheQueryTakesTheWidth() throws {
        let mounted = mount()
        defer { mounted.window.close() }
        let bar = mounted.bar
        bar.searchString = "claude"
        bar.numberOfMatches = 12
        mounted.window.contentView?.layoutSubtreeIfNeeded()

        let field = bar.field.convert(bar.field.bounds, to: bar)
        let count = bar.countLabel.convert(bar.countLabel.bounds, to: bar)
        let done = bar.doneButton.convert(bar.doneButton.bounds, to: bar)
        XCTAssertGreaterThan(field.width, 300, "the query was squeezed")
        XCTAssertLessThanOrEqual(field.maxX, count.minX, "the count sits on the query")
        XCTAssertEqual(done.maxX, bar.bounds.maxX - 8, accuracy: 1)
        XCTAssertEqual(bar.bounds.height, FindBarView.height)
    }

    // MARK: - Harness

    private struct Mounted {
        let window: NSWindow
        let bar: FindBarView
        let recorder: Recorder
    }

    private func mount() -> Mounted {
        let window = TestWindow.make(contentSize: NSSize(width: 640, height: 60))
        let bar = FindBarView()
        let recorder = Recorder()
        bar.delegate = recorder
        bar.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        window.contentView = root
        root.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.topAnchor.constraint(equalTo: root.topAnchor),
        ])
        root.layoutSubtreeIfNeeded()
        return Mounted(window: window, bar: bar, recorder: recorder)
    }

    /// Presses one segment the way VoiceOver does. Not a synthesized click: the
    /// control's tracking, laid out by constraints, never sends its action for one
    /// (measured — the same click lands when the frame is set by hand, and always
    /// with a cell-based control), and its momentary `selectedSegment` does not
    /// hold a value written from outside.
    private func press(segment: Int, of control: NSSegmentedControl) {
        // The control's one child is its cell; the segments are the cell's.
        let segments =
            control.accessibilityChildren()?
            .compactMap { ($0 as? NSCell)?.accessibilityChildren() }
            .flatMap { $0 } ?? []
        guard segments.indices.contains(segment) else {
            return XCTFail("no accessible segment \(segment)")
        }
        // `NSAccessibilitySegment` is private, so the press goes by selector.
        let element = segments[segment] as AnyObject
        let press = #selector(NSAccessibilityButton.accessibilityPerformPress)
        XCTAssertTrue(element.responds(to: press), "segment \(segment) cannot be pressed")
        _ = element.perform(press)
    }

    /// The field editor, with the caret in the field — where keystrokes land.
    private func beginTyping(_ mounted: Mounted) throws -> NSTextView {
        mounted.window.makeFirstResponder(mounted.bar.field)
        return try XCTUnwrap(
            mounted.bar.field.currentEditor() as? NSTextView, "the field took no editor")
    }
}

/// The actions, compared and printed by their names: `NSTextFinder.Action`
/// prints only its type, which makes a failed comparison unreadable.
private struct Actions: Equatable, ExpressibleByArrayLiteral, CustomStringConvertible {

    var values: [NSTextFinder.Action] = []

    init(arrayLiteral elements: NSTextFinder.Action...) { values = elements }

    var description: String {
        values.map { action in
            switch action {
            case .nextMatch: "next"
            case .previousMatch: "previous"
            case .hideFindInterface: "hide"
            case .showFindInterface: "show"
            default: "\(action.rawValue)"
            }
        }.description
    }
}

@MainActor
private final class Recorder: FindBarViewDelegate {

    var queries: [String] = []
    private(set) var actions = Actions()

    func findBarView(_ findBarView: FindBarView, didChangeSearchString searchString: String) {
        queries.append(searchString)
    }

    func findBarView(_ findBarView: FindBarView, didRequest action: NSTextFinder.Action) {
        actions.values.append(action)
    }
}
