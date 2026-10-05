import XCTest

@testable import DisplayModels

/// How a check's problem reads under its field: the reason as a sentence,
/// then what stays in use.
final class ValidationDetailTests: XCTestCase {
    private func localized(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .module)
    }

    func testAReasonBecomesASentence() {
        XCTAssertEqual(
            ValidationDetail.problem("Not found", fallback: nil),
            ValidationDetail(text: localized("\("Not found")."), isError: true))
    }

    func testAReasonThatEndsInPunctuationGetsNoSecondOne() {
        XCTAssertEqual(ValidationDetail.problem("Command failed.", fallback: nil).text, "Command failed.")
        XCTAssertEqual(ValidationDetail.problem("找不到。", fallback: nil).text, "找不到。")
    }

    func testWhatStaysInUseFollowsTheReason() {
        let detail = ValidationDetail.problem("Folder doesn’t exist", fallback: "~/.claude")
        XCTAssertEqual(
            detail.text, localized("\("Folder doesn’t exist").") + " " + localized("Still using \("~/.claude")."))
        XCTAssertTrue(detail.isError)
    }

    func testCheckingIsNotAProblemAndNoneSaysNothing() {
        XCTAssertEqual(ValidationDetail.checking, ValidationDetail(text: localized("Checking…"), isError: false))
        XCTAssertNil(ValidationDetail.none.text)
        XCTAssertFalse(ValidationDetail.none.isError)
    }
}
