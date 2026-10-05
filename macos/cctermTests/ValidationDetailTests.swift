import AgentSDK
import Components
import DisplayModels
import XCTest

@testable import ccterm

/// The line under a field for each state of its check, for launch commands
/// and for folders.
final class ValidationDetailTests: XCTestCase {
    private let version = CLIVersion(executable: "/usr/local/bin/claude", version: "2.1.0")

    func testACommandBeingCheckedSaysSo() {
        let detail = LaunchCommandValidation.State.checking.detail(fallback: "claude")
        XCTAssertEqual(detail, .checking)
    }

    func testAWorkingCommandShowsItsVersionWithoutThePath() {
        let detail = LaunchCommandValidation.State.valid(version).detail(fallback: "claude")
        XCTAssertEqual(detail.text, String(localized: "Claude Code \("2.1.0")"))
        XCTAssertFalse(detail.isError)
        XCTAssertFalse(detail.text?.contains("/usr/local") ?? true)
    }

    func testAFailingCommandIsAProblemWithWhatStaysInUse() {
        let alone = LaunchCommandValidation.State.invalid("Not found").detail(fallback: nil)
        XCTAssertEqual(alone, .problem("Not found", fallback: nil))

        let kept = LaunchCommandValidation.State.invalid("Not found").detail(fallback: "orange")
        XCTAssertEqual(kept, .problem("Not found", fallback: "orange"))
    }

    func testAFolderSaysWhatItHoldsOrWhyItCannotBeUsed() {
        XCTAssertEqual(FolderValidation.State.checking.detail(fallback: nil), .checking)
        let valid = FolderValidation.State.valid(()).detail(fallback: "~/.claude")
        XCTAssertEqual(valid.text, String(localized: "Claude Code’s settings, sign-in and sessions"))
        XCTAssertFalse(valid.isError)

        let invalid = FolderValidation.State.invalid("Folder doesn’t exist").detail(fallback: "~/.claude")
        XCTAssertEqual(invalid, .problem("Folder doesn’t exist", fallback: "~/.claude"))
    }

    func testNothingToSayShowsNoText() {
        XCTAssertNil(ValidationDetail.none.text)
        XCTAssertFalse(ValidationDetail.none.isError)
    }
}
