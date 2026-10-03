import AgentSDK
import AppKit
import Combine
import Components
import TranscriptKit
import XCTest

@testable import ccterm

/// Send in a New tab, in the order the tab documents: the session starts at
/// once, the page rises, the composer's place is captured, the window is told
/// before anything swaps, then the New view goes, the transcript comes and the
/// composer glides down from where it stood.
///
/// The CLI's own part — the held prompt, *Starting*, Stop taking the words back
/// — is the store's (`SessionStoreTests`); here the store only reads, so a
/// started session is a URL and nothing launches.
@MainActor
final class SessionTabHandoverTests: XCTestCase {
    private var stage: AppKitStage?
    private let recorder = TabRecorder()

    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        stage?.teardown()
    }

    private func mountDraft(folder: URL? = URL(fileURLWithPath: "/tmp/repo")) -> SessionTabViewController {
        let context = TranscriptTab.Context.reading()
        let tab = SessionTabViewController(
            .draft(folder: folder, text: ""), title: SessionTabTitle.draft, context: context)
        tab.tabDelegate = recorder
        stage = AppKitStage.mount(tab, size: CGSize(width: 900, height: 700))
        tab.viewDidAppear()
        stage!.drain()
        return tab
    }

    private func composer(of tab: SessionTabViewController) throws -> ComposerViewController {
        try XCTUnwrap(tab.children.compactMap { $0 as? ComposerViewController }.first)
    }

    /// Types `text` and presses Send, as the composer reports it: the field is
    /// cleared before the tab hears.
    private func send(_ text: String, in tab: SessionTabViewController) throws {
        let composer = try composer(of: tab)
        composer.text = ""
        tab.composerViewController(composer, didSubmit: text)
    }

    private func windowFrame(of composer: ComposerViewController) -> NSRect {
        composer.view.convert(composer.view.bounds, to: nil)
    }

    // MARK: - The order

    func testTheWindowIsToldBeforeTheNewViewGoesAndTheTranscriptComesAfter() throws {
        let tab = mountDraft()
        XCTAssertTrue(tab.children.contains { $0 is NewSessionViewController }, "premise: it is a New tab")

        try send("Fix the gutter", in: tab)
        XCTAssertTrue(stage!.drainUntil(timeout: 5) { self.recorder.started.count == 1 }, "the window was never told")

        let children = try XCTUnwrap(recorder.childrenAtStart.first)
        XCTAssertTrue(
            children.contains("NewSessionViewController"),
            "the New view had gone when the window was told: \(children)")
        XCTAssertFalse(children.contains("TranscriptViewController"), "the transcript came before the window was told")
        XCTAssertEqual(tab.transcriptURL, recorder.started[0])
        XCTAssertEqual(recorder.started[0].pathExtension, "jsonl")

        XCTAssertTrue(stage!.drainUntil(timeout: 5) { tab.children.contains { $0 is TranscriptViewController } })
        XCTAssertFalse(tab.children.contains { $0 is NewSessionViewController }, "the New view stayed")
        XCTAssertEqual(recorder.started.count, 1, "the window was told twice")
        XCTAssertNil(tab.draftText, "it is a session's tab now")
    }

    /// The session is real from the first moment: the tab is its session's
    /// before the CLI has written a line.
    func testTheTabIsTheSessionsAtOnce() throws {
        let tab = mountDraft()

        try send("Fix the gutter", in: tab)
        XCTAssertTrue(stage!.drainUntil(timeout: 5) { tab.transcriptURL != nil })

        XCTAssertEqual(tab.transcriptURL, recorder.started.first)
        XCTAssertFalse(tab.isUntouchedDraft)
    }

    func testTheTabIsNamedForThePromptsFirstLine() throws {
        let tab = mountDraft()

        try send("Fix the gutter overflow\nand then the margin", in: tab)
        XCTAssertTrue(stage!.drainUntil(timeout: 5) { tab.transcriptURL != nil })

        XCTAssertEqual(tab.title, "Fix the gutter overflow")
    }

    func testALongPromptIsCutAtFortyCharactersInTheTitle() throws {
        let tab = mountDraft()
        let long = String(repeating: "word ", count: 20)

        try send(long, in: tab)
        XCTAssertTrue(stage!.drainUntil(timeout: 5) { tab.transcriptURL != nil })

        XCTAssertEqual(tab.title, SessionTabTitle.fromPrompt(long))
        XCTAssertLessThanOrEqual(try XCTUnwrap(tab.title).count, 41)
    }

    /// Nothing to launch in: the words stay in the field, and the tab stays a
    /// New tab.
    func testSendWithoutAFolderKeepsTheWordsAndStaysANewTab() throws {
        let tab = mountDraft(folder: nil)

        try send("Fix the gutter", in: tab)
        stage!.drain(seconds: 0.2)

        XCTAssertTrue(recorder.started.isEmpty)
        XCTAssertNil(tab.transcriptURL)
        XCTAssertEqual(try composer(of: tab).text, "Fix the gutter")
        XCTAssertTrue(tab.children.contains { $0 is NewSessionViewController })
    }

    // MARK: - Geometry

    /// Nothing jumps: right after the swap the card's top edge is where it
    /// stood in the New view (the key hints under it are gone), not at the
    /// bottom; the transcript is the whole tab.
    func testTheComposerStartsTheGlideWhereItStood() throws {
        let tab = mountDraft()
        let composer = try composer(of: tab)
        tab.view.layoutSubtreeIfNeeded()
        let before = windowFrame(of: composer)
        XCTAssertGreaterThan(before.height, 20, "premise: the composer was laid out")

        try send("Fix the gutter", in: tab)
        XCTAssertTrue(stage!.drainUntil(timeout: 5) { tab.children.contains { $0 is TranscriptViewController } })
        let after = windowFrame(of: composer)

        let rest = tab.view.convert(tab.view.bounds, to: nil).minY + 16
        XCTAssertGreaterThan(
            abs(before.minY - rest), 40, "premise: the New view's composer is not already at the bottom")
        XCTAssertEqual(after.maxY, before.maxY, accuracy: 0.5, "the card jumped at the swap")
        XCTAssertEqual(after.width, before.width, accuracy: 4)
        let transcript = try XCTUnwrap(stage!.find(TranscriptView.self))
        XCTAssertEqual(tab.view.convert(transcript.bounds, from: transcript), tab.view.bounds)
    }

    /// Needs the display awake: the glide advances on display refreshes.
    func testTheComposerEndsFloatingSixteenAboveTheBottomAtSevenTwenty() throws {
        let tab = mountDraft()
        let composer = try composer(of: tab)
        tab.view.layoutSubtreeIfNeeded()

        try send("Fix the gutter", in: tab)

        XCTAssertTrue(
            stage!.drainUntil(timeout: 5) {
                abs(composer.view.convert(composer.view.bounds, to: tab.view).minY - 16) < 0.5
            }, "the composer never reached its place (is the display asleep?)")
        let card = composer.view.convert(composer.view.bounds, to: tab.view)
        XCTAssertEqual(card.width, 720, accuracy: 0.5)
        XCTAssertEqual(card.midX, tab.view.bounds.midX, accuracy: 0.5)
        // What the card covers is the transcript's safe area, nothing more.
        let transcript = try XCTUnwrap(tab.children.compactMap { $0 as? TranscriptViewController }.first)
        XCTAssertEqual(transcript.view.safeAreaInsets.bottom, card.height + 16, accuracy: 0.5)
        XCTAssertFalse(try XCTUnwrap(find(SessionTabDockView.self, in: tab.view) { _ in true }).isHidden)
    }

    /// The dock is the session's: a New tab shows none.
    func testANewTabShowsNoDock() throws {
        let tab = mountDraft()

        XCTAssertTrue(try XCTUnwrap(find(SessionTabDockView.self, in: tab.view) { _ in true }).isHidden)
    }

    /// Needs the display awake: samples the composer's frames. Until the swap
    /// the card's top edge holds still (in the page, the key hints under it);
    /// from the swap the glide moves its bottom edge, only ever down, to rest.
    /// The card may grow on the way (the session's first state), upward.
    func testTheGlideMovesMonotonicallyDownward() throws {
        let tab = mountDraft()
        let composer = try composer(of: tab)
        tab.view.layoutSubtreeIfNeeded()
        let start = composer.view.convert(composer.view.bounds, to: tab.view)

        try send("Fix the gutter", in: tab)
        var samples: [NSRect] = []
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0 / 120))
            samples.append(composer.view.convert(composer.view.bounds, to: tab.view))
            if let last = samples.last, abs(last.minY - 16) < 0.5, samples.count > 5 { break }
        }

        XCTAssertGreaterThan(samples.count, 5, "the glide produced no frames (is the display asleep?)")
        XCTAssertEqual(try XCTUnwrap(samples.last).minY, 16, accuracy: 0.5)
        let page = samples.prefix { abs($0.height - start.height) < 0.5 }
        let gliding = samples.dropFirst(page.count)
        for frame in page {
            XCTAssertEqual(frame.maxY, start.maxY, accuracy: 0.5, "the card moved before the swap")
        }
        XCTAssertEqual(try XCTUnwrap(gliding.first).maxY, start.maxY, accuracy: 0.5, "the card jumped at the swap")
        for (earlier, later) in zip(gliding, gliding.dropFirst()) {
            XCTAssertLessThanOrEqual(later.minY, earlier.minY + 0.5, "the composer went back up mid-glide")
        }
    }

    /// Step 1: the words stay, dimmed — the words, not the composer — until the
    /// session's tab takes over.
    func testOnlyTheWordsAreDimmedWhileTheSendHands() throws {
        let tab = mountDraft()
        let composer = try composer(of: tab)

        try send("Fix the gutter", in: tab)

        XCTAssertTrue(composer.isFieldDimmed)
        XCTAssertEqual(composer.view.alphaValue, 1, "the whole composer was dimmed")
        XCTAssertTrue(stage!.drainUntil(timeout: 5) { tab.children.contains { $0 is TranscriptViewController } })
        XCTAssertFalse(composer.isFieldDimmed, "the session's tab kept the field dimmed")
    }

    /// While the page rises the composer already says Starting, with Stop to
    /// cancel — not a ready Send.
    func testTheComposerSaysStartingDuringTheRise() throws {
        let tab = mountDraft()
        let composer = try composer(of: tab)

        try send("Fix the gutter", in: tab)

        let stop = try XCTUnwrap(
            find(NSButton.self, in: composer.view) { $0.toolTip == String(localized: "Cancel ⌘.") })
        XCTAssertFalse(stop.isHidden, "the stop button is not offered while starting")
    }

    /// Stop during the rise cancels the launch: the rise's completion does
    /// nothing, the words stay, the tab stays the draft and the window is told
    /// nothing.
    func testStopDuringTheRiseCancelsTheHandover() throws {
        let tab = mountDraft()
        let composer = try composer(of: tab)
        try send("Fix the gutter", in: tab)
        XCTAssertTrue(composer.isFieldDimmed, "premise: the handover is under way")

        let newView = try XCTUnwrap(tab.children.first { $0 is NewSessionViewController }).view
        XCTAssertNotNil(layer(named: "rise-row-0", in: newView)?.animation(forKey: "flash"), "premise: the rise plays")

        tab.composerViewControllerDidRequestStop(composer)
        XCTAssertNil(
            layer(named: "rise-row-0", in: newView)?.animation(forKey: "flash"), "the rise played on after Stop")
        stage!.drain(seconds: 1.0)

        XCTAssertTrue(recorder.started.isEmpty, "the window was told a session started")
        XCTAssertEqual(recorder.returnedToDraft, 0)
        XCTAssertNil(tab.transcriptURL)
        XCTAssertTrue(tab.children.contains { $0 is NewSessionViewController }, "the New view went")
        XCTAssertFalse(tab.children.contains { $0 is TranscriptViewController })
        XCTAssertEqual(composer.text, "Fix the gutter")
        XCTAssertFalse(composer.isFieldDimmed)
        XCTAssertNotNil(tab.draftText)
        // And the tab can send again.
        try send("Again", in: tab)
        XCTAssertTrue(stage!.drainUntil(timeout: 5) { self.recorder.started.count == 1 })
    }

    private func layer(named name: String, in root: NSView) -> CALayer? {
        func search(_ layer: CALayer) -> CALayer? {
            if layer.name == name { return layer }
            return (layer.sublayers ?? []).lazy.compactMap(search).first
        }
        if let found = root.layer.flatMap(search) { return found }
        return root.subviews.lazy.compactMap { self.layer(named: name, in: $0) }.first
    }

    private func find<V: NSView>(_ type: V.Type, in root: NSView, where match: (V) -> Bool) -> V? {
        if let found = root as? V, match(found) { return found }
        for subview in root.subviews { if let found = find(type, in: subview, where: match) { return found } }
        return nil
    }
}
