import AppKit
import XCTest

@testable import TranscriptSource

/// `SourceView` as the window server composited it, in both appearances:
/// `/tmp/transcriptkit-screenshots/SourceView-{comparison,output}-{light,dark}.png`.
///
/// **For eyes, not a gate.** Compare the comparison against Xcode's Code Review
/// (Editor ▸ Code Review, Inline Comparison) on the same text: removed lines on
/// red with no number, added lines on green with the changed word marked, a
/// striped blue bar beside each change, doc comments in a proportional face.
@MainActor
final class SourceViewSnapshotTests: XCTestCase {

    private static let original = """
        import AgentSDK
        import AppKit
        import TranscriptKit

        /// One editor tab: a transcript file, read-only, in a `TranscriptView`.
        @MainActor
        final class TranscriptViewController: NSViewController {
            /// The file this tab shows — what the tab is, for finding it again.
            let fileURL: URL

            private let transcript = TranscriptView()
            private var rows: [TranscriptRow] = []
            private var hasLoaded = false

            // MARK: - Loading

            override func viewDidAppear() {
                super.viewDidAppear()
                guard !hasLoaded else { return }
                let note = "Loaded \\(rows.count) rows" // a comment
                transcript.maxContentWidth = 720 + 0.5
            }
        }
        """

    private static let edited = """
        import AgentSDK
        import AppKit
        import Combine
        import TranscriptKit

        /// One editor tab: a session transcript, read-only, in a `TranscriptView`.
        @MainActor
        final class TranscriptViewController: NSViewController {
            /// The file this tab shows — what the tab is, for finding it again.

            private let transcript = TranscriptView()
            private var rows: [TranscriptRow] = []
            private var hasLoaded = true
            private var extra = 0

            // MARK: - Loading

            override func viewDidAppear() {
                super.viewDidAppear()
                guard !hasLoaded else { return }
                let note = "Loaded \\(rows.count) rows" // a comment, long enough that the line has to wrap at this width
                transcript.maxContentWidth = 720 + 0.5
            }
        }
        """

    func testComparison() async throws {
        let document = SourceDocument(old: Self.original, new: Self.edited, language: .swift)
        XCTAssertEqual(document.changes.count, 5)
        try await capture(document, named: "SourceView-comparison")
    }

    func testCommandOutput() async throws {
        let output = """
            \u{1B}[1mCompiling\u{1B}[0m TranscriptSource SourceView.swift
            \u{1B}[33mwarning:\u{1B}[0m variable 'x' was never used
            \u{1B}[31merror:\u{1B}[0m cannot find 'y' in scope
            \u{1B}[32m✔\u{1B}[0m Executed 20 tests, with 0 failures
            \u{1B}[2mdim note\u{1B}[0m and \u{1B}[36mcyan\u{1B}[0m and \u{1B}[34mblue\u{1B}[0m and \u{1B}[35mmagenta\u{1B}[0m
            """
        try await capture(SourceDocument(terminalOutput: output), named: "SourceView-output")
    }

    private func capture(_ document: SourceDocument, named name: String) async throws {
        let size = NSSize(width: 620, height: 460)
        let window = TestWindow.make(contentSize: size)
        defer { window.close() }
        let view = SourceView(document: document)
        view.frame = NSRect(origin: .zero, size: size)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        window.layoutIfNeeded()
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            window.displayIfNeeded()
            let url = try await WindowCapture.capture(window, named: "\(name)-\(suffix)")
            add(XCTAttachment(contentsOfFile: url))
        }
    }
}
