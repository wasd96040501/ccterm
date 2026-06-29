import XCTest

@testable import ccterm

/// Non-snapshot CI-gate coverage for `BackgroundTaskFormat` — the SwiftUI-free
/// formatting helpers lifted verbatim out of the deleted `BackgroundTaskRow.swift`
/// during the D8 dead-SwiftUI sweep. These pure string functions back the AppKit
/// `BackgroundTaskPickerController` row subtitle + `BackgroundTaskDetailPresenter`,
/// so a silent regression (e.g. the minutes/hours rollover at 60) would surface
/// only in the live popover. Drive the real statics directly and assert the
/// observable output.
///
/// Assertions use the English source strings — `String(localized:)` returns the
/// key verbatim in the default test locale.
@MainActor
final class BackgroundTaskFormatTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - formatElapsed duration ladder (<1s / Ns / Nm Ns / Nh Nm)
    //
    // The seconds / minutes / hours branches build their string with raw
    // interpolation, so they are locale-independent and asserted against
    // literals. The sub-second branch is the only one routed through
    // `String(localized: "<1s")`, so it is pinned to the same localized source
    // (the test host can run in any locale — zh-Hans on CI) rather than a
    // hardcoded English literal. The load-bearing fact — that the value is the
    // sub-second branch and is distinct from the `1s` seconds branch — is still
    // asserted directly.

    private static let subSecond = String(localized: "<1s")

    func testFormatElapsedSubSecondReadsLessThanOneSecond() {
        XCTAssertEqual(BackgroundTaskFormat.formatElapsed(0), Self.subSecond)
        XCTAssertEqual(BackgroundTaskFormat.formatElapsed(0.5), Self.subSecond)
        XCTAssertEqual(
            BackgroundTaskFormat.formatElapsed(0.999), Self.subSecond,
            "Anything strictly below 1s is the '<1s' branch.")
        XCTAssertNotEqual(
            BackgroundTaskFormat.formatElapsed(0.999), "1s",
            "The sub-second branch must be distinct from the seconds branch.")
    }

    func testFormatElapsedSecondsBranchTruncatesTowardZero() {
        XCTAssertEqual(
            BackgroundTaskFormat.formatElapsed(1), "1s",
            "Exactly 1s crosses out of the '<1s' branch.")
        XCTAssertEqual(
            BackgroundTaskFormat.formatElapsed(1.9), "1s",
            "Int(interval) truncates — 1.9s reads 1s, not 2s.")
        XCTAssertEqual(BackgroundTaskFormat.formatElapsed(45), "45s")
        XCTAssertEqual(
            BackgroundTaskFormat.formatElapsed(59), "59s",
            "59s is the last value before the minutes rollover.")
    }

    func testFormatElapsedMinutesRolloverAtSixty() {
        XCTAssertEqual(
            BackgroundTaskFormat.formatElapsed(60), "1m 0s",
            "60s rolls into the 'Nm Ns' branch with 0 remainder seconds.")
        XCTAssertEqual(BackgroundTaskFormat.formatElapsed(63), "1m 3s")
        XCTAssertEqual(BackgroundTaskFormat.formatElapsed(125), "2m 5s")
        XCTAssertEqual(
            BackgroundTaskFormat.formatElapsed(3599), "59m 59s",
            "3599s is the last value before the hours rollover.")
    }

    func testFormatElapsedHoursRolloverDropsSeconds() {
        XCTAssertEqual(
            BackgroundTaskFormat.formatElapsed(3600), "1h 0m",
            "3600s rolls into the 'Nh Nm' branch; seconds are dropped at this scale.")
        XCTAssertEqual(
            BackgroundTaskFormat.formatElapsed(3660), "1h 1m",
            "61 minutes reads 1h 1m.")
        XCTAssertEqual(
            BackgroundTaskFormat.formatElapsed(7385), "2h 3m",
            "7385s = 2h 3m 5s, seconds elided in the hours branch.")
    }

    // MARK: - statusLabel for each BackgroundTask.Status
    //
    // Each label is `String(localized:)`, so it is pinned to the same localized
    // source the production row reads (locale-independent). The load-bearing
    // fact the row depends on — that every status maps to a *distinct*,
    // non-empty label — is asserted explicitly so a copy/paste regression
    // (e.g. two cases returning the same key) is caught.

    func testStatusLabelCoversEveryStatusCase() {
        XCTAssertEqual(BackgroundTaskFormat.statusLabel(.running), String(localized: "Running"))
        XCTAssertEqual(BackgroundTaskFormat.statusLabel(.completed), String(localized: "Completed"))
        XCTAssertEqual(BackgroundTaskFormat.statusLabel(.failed), String(localized: "Failed"))
        XCTAssertEqual(BackgroundTaskFormat.statusLabel(.stopped), String(localized: "Stopped"))

        let labels: [BackgroundTask.Status] = [.running, .completed, .failed, .stopped]
        let resolved = labels.map(BackgroundTaskFormat.statusLabel)
        XCTAssertFalse(resolved.contains(where: \.isEmpty), "Every status maps to a non-empty label.")
        XCTAssertEqual(
            Set(resolved).count, labels.count,
            "Each status maps to a distinct label.")
    }

    // MARK: - statusedSubtitle composition

    func testStatusedSubtitleJoinsLabelAndTimingWithMiddleDot() {
        let task = makeTask(status: .running, startedAt: Date(), endedAt: nil)
        XCTAssertEqual(
            BackgroundTaskFormat.statusedSubtitle(task: task, timing: "2m 15s"),
            "\(BackgroundTaskFormat.statusLabel(.running)) · 2m 15s",
            "Subtitle is 'label · timing' joined with a middle dot.")

        let done = makeTask(status: .completed, startedAt: Date(), endedAt: Date())
        XCTAssertEqual(
            BackgroundTaskFormat.statusedSubtitle(task: done, timing: "4s"),
            "\(BackgroundTaskFormat.statusLabel(.completed)) · 4s")

        // The middle-dot separator and the verbatim timing are the load-bearing
        // structure, independent of how the label localizes.
        XCTAssertTrue(
            BackgroundTaskFormat.statusedSubtitle(task: done, timing: "4s").hasSuffix(" · 4s"),
            "Timing is appended verbatim after ' · '.")
    }

    // MARK: - elapsedDescription endpoint selection (endedAt ?? now)

    func testElapsedDescriptionUsesEndedAtWhenTerminal() {
        let started = Date(timeIntervalSinceReferenceDate: 1_000)
        let ended = started.addingTimeInterval(63)
        let task = makeTask(status: .completed, startedAt: started, endedAt: ended)
        // `now` is far past the end — a terminal task must clamp to endedAt, not now.
        let now = started.addingTimeInterval(10_000)
        XCTAssertEqual(BackgroundTaskFormat.elapsedDescription(task: task, now: now), "1m 3s")
    }

    func testElapsedDescriptionUsesNowWhileRunning() {
        let started = Date(timeIntervalSinceReferenceDate: 2_000)
        let task = makeTask(status: .running, startedAt: started, endedAt: nil)
        let now = started.addingTimeInterval(45)
        XCTAssertEqual(BackgroundTaskFormat.elapsedDescription(task: task, now: now), "45s")
    }

    func testElapsedDescriptionClampsNegativeIntervalToZero() {
        // A `now` before `startedAt` (clock skew / out-of-order sample) must not
        // produce a negative interval — `max(0, …)` lands it on the '<1s' branch.
        let started = Date(timeIntervalSinceReferenceDate: 3_000)
        let task = makeTask(status: .running, startedAt: started, endedAt: nil)
        let now = started.addingTimeInterval(-50)
        XCTAssertEqual(BackgroundTaskFormat.elapsedDescription(task: task, now: now), Self.subSecond)
    }

    // MARK: - Fixture

    private func makeTask(
        status: BackgroundTask.Status,
        startedAt: Date,
        endedAt: Date?
    ) -> BackgroundTask {
        BackgroundTask(
            id: UUID().uuidString,
            toolUseId: nil,
            description: nil,
            taskType: nil,
            command: nil,
            outputFile: nil,
            startedAt: startedAt,
            endedAt: endedAt,
            status: status,
            summary: nil)
    }
}
