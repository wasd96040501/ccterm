import AgentSDK
import AppKit
import TranscriptKit
import XCTest

@testable import ccterm

/// What a session tab's container needs from its transcript: the space its
/// floating composer covers (`bottomInset`) without moving the reader, and
/// whether the request waiting for them is in view.
@MainActor
final class TranscriptViewControllerWaitingTests: XCTestCase {
    private var stage: AppKitStage?
    private let recorder = VisibilityRecorder()

    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        stage?.teardown()
    }

    /// `turns` prompts and answers, then — when `waiting` — a Bash call asking
    /// leave, and the request that holds it.
    private func state(turns: Int, waiting: Bool) -> SessionState {
        var script = MessageScript()
        for turn in 0..<turns {
            script.prompt("Question \(turn)")
            script.reply("Answer **\(turn)**")
        }
        var state = SessionState(transcript: Transcript(messages: script.messages))
        if waiting {
            script.prompt("Run it")
            script.call("c1", "Bash", #"{"command":"make"}"#)
            state = SessionState(transcript: Transcript(messages: script.messages))
            state.requests = [
                PermissionRequest(
                    toolName: "Bash", toolUseID: "c1", input: MessageScript.json(#"{"command":"make"}"#),
                    onRespond: { _ in })
            ]
        }
        return state
    }

    private func mount(_ state: SessionState) throws -> (TranscriptViewController, TranscriptView) {
        let controller = TranscriptViewController(
            fileURL: URL(fileURLWithPath: "/nonexistent/s.jsonl"), title: "t", sessions: .reading())
        controller.delegate = recorder
        let stage = AppKitStage.mount(controller, size: CGSize(width: 800, height: 500))
        self.stage = stage
        stage.rootViewController.viewDidAppear()
        controller.show(state)
        let transcript = try XCTUnwrap(stage.find(TranscriptView.self))
        XCTAssertTrue(stage.drainUntil(timeout: 10) { transcript.numberOfRows > 40 }, "premise: the page was shown")
        stage.drain(seconds: 0.2)
        return (controller, transcript)
    }

    // MARK: - The reader's place

    /// The card floats over the bottom: a taller one gives the last row more
    /// room, and a reader who scrolled up keeps the row they were on.
    func testGrowingTheBottomInsetKeepsTheReadersPlace() throws {
        let (controller, transcript) = try mount(state(turns: 40, waiting: false))
        transcript.scrollToRow(at: 30, scrollPosition: .top)
        stage!.drain(seconds: 0.2)
        let before = transcript.rect(ofRow: 30).minY
        XCTAssertEqual(before, 0, accuracy: 20, "premise: the row is at the top of the view")

        controller.bottomInset = 160
        stage!.drain(seconds: 0.2)

        XCTAssertEqual(transcript.rect(ofRow: 30).minY, before, accuracy: 0.5, "the rows moved under the reader")
    }

    /// At the end it stays at the end: the last row comes to rest above the card.
    func testAtTheEndTheLastRowStaysClearOfTheCard() throws {
        let (controller, transcript) = try mount(state(turns: 40, waiting: false))
        let last = transcript.numberOfRows - 1
        XCTAssertGreaterThan(transcript.rect(ofRow: last).maxY, 0, "premise: the last row is laid out")

        controller.bottomInset = 160
        stage!.drain(seconds: 0.2)

        XCTAssertLessThanOrEqual(
            transcript.rect(ofRow: last).maxY, transcript.bounds.height - 160 + 0.5,
            "the last row is under the card")
        XCTAssertGreaterThan(transcript.rect(ofRow: last).maxY, transcript.bounds.height - 160 - 40)
    }

    // MARK: - The waiting request

    func testARequestAtTheEndIsInView() throws {
        _ = try mount(state(turns: 40, waiting: true))

        XCTAssertEqual(recorder.reports.last, true)
    }

    /// Scrolled away from it, the composer is told, and *Waiting for you ↑*
    /// brings it back.
    func testScrollingAwayReportsItAndRevealingBringsItBack() throws {
        let (controller, transcript) = try mount(state(turns: 40, waiting: true))
        XCTAssertEqual(recorder.reports.last, true, "premise")

        transcript.scrollToRow(at: 0, scrollPosition: .top)
        stage!.drain(seconds: 0.3)
        XCTAssertEqual(recorder.reports.last, false, "the request is off screen and nobody was told")

        controller.revealWaitingRequest()
        stage!.drain(seconds: 0.3)
        XCTAssertEqual(recorder.reports.last, true, "revealing did not bring the request into view")
    }

    func testNothingWaitingIsAlwaysInView() throws {
        let (_, transcript) = try mount(state(turns: 40, waiting: false))
        transcript.scrollToRow(at: 0, scrollPosition: .top)
        stage!.drain(seconds: 0.3)

        XCTAssertFalse(recorder.reports.contains(false))
    }
}

@MainActor
private final class VisibilityRecorder: TranscriptViewControllerDelegate {
    var reports: [Bool] = []

    func transcriptViewController(
        _ transcriptViewController: TranscriptViewController, didChangeWaitingRequestVisibility isVisible: Bool
    ) {
        reports.append(isVisible)
    }

    func transcriptViewControllerDidRequestComposer(_ transcriptViewController: TranscriptViewController) {}
}
