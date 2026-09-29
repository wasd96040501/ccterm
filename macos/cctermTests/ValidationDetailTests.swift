import AgentSDK
import XCTest

@testable import ccterm

/// The line under a field for each state of its check, for launch commands
/// and for folders.
final class ValidationDetailTests: XCTestCase {
    private let version = CLIVersion(executable: "/usr/local/bin/claude", version: "2.1.0")

    func testACommandBeingCheckedSaysSo() {
        let detail = LaunchCommandValidation.State.checking.detail(fallback: "claude")
        XCTAssertEqual(detail, ValidationDetail(text: String(localized: "Checking…"), isError: false))
    }

    func testAWorkingCommandShowsItsVersionWithoutThePath() {
        let detail = LaunchCommandValidation.State.valid(version).detail(fallback: "claude")
        XCTAssertEqual(detail.text, String(localized: "Claude Code \("2.1.0")"))
        XCTAssertFalse(detail.isError)
        XCTAssertFalse(detail.text?.contains("/usr/local") ?? true)
    }

    func testAFailingCommandGivesItsReasonAsASentenceAndWhatStaysInUse() {
        let alone = LaunchCommandValidation.State.invalid("Not found").detail(fallback: nil)
        XCTAssertEqual(alone, ValidationDetail(text: String(localized: "\("Not found")."), isError: true))

        let kept = LaunchCommandValidation.State.invalid("Not found").detail(fallback: "orange")
        XCTAssertEqual(
            kept.text, String(localized: "\("Not found").") + " " + String(localized: "Still using \("orange")."))
        XCTAssertTrue(kept.isError)
    }

    func testAReasonThatEndsInPunctuationGetsNoSecondOne() {
        let detail = LaunchCommandValidation.State.invalid("Command failed.").detail(fallback: nil)
        XCTAssertEqual(detail.text, "Command failed.")
    }

    func testAFolderSaysWhatItHoldsOrWhyItCannotBeUsed() {
        XCTAssertEqual(FolderValidation.State.checking.detail(fallback: nil), .checking)
        let valid = FolderValidation.State.valid(()).detail(fallback: "~/.claude")
        XCTAssertEqual(valid.text, String(localized: "Claude Code’s settings, sign-in and sessions"))
        XCTAssertFalse(valid.isError)

        let invalid = FolderValidation.State.invalid("Folder doesn’t exist").detail(fallback: "~/.claude")
        XCTAssertEqual(
            invalid.text,
            String(localized: "\("Folder doesn’t exist").") + " " + String(localized: "Still using \("~/.claude")."))
        XCTAssertTrue(invalid.isError)
    }

    func testNothingToSayShowsNoText() {
        XCTAssertNil(ValidationDetail.none.text)
        XCTAssertFalse(ValidationDetail.none.isError)
    }
}
