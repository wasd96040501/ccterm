import XCTest

@testable import Components

/// Back and forward through the Settings panes, by index.
final class SettingsHistoryTests: XCTestCase {
    private let general = 0
    private let accounts = 1

    func testBackAndForwardWalkThePanesVisited() {
        var history = SettingsHistory(accounts)
        XCTAssertFalse(history.canGoBack)
        history.go(to: general)
        XCTAssertEqual(history.current, general)
        XCTAssertTrue(history.canGoBack)
        history.goBack()
        XCTAssertEqual(history.current, accounts)
        XCTAssertTrue(history.canGoForward)
        history.goForward()
        XCTAssertEqual(history.current, general)
        XCTAssertFalse(history.canGoForward)
    }

    func testGoingSomewhereNewDropsForwardAndStayingPutRecordsNothing() {
        var history = SettingsHistory(accounts)
        history.go(to: general)
        history.goBack()
        history.go(to: accounts)
        XCTAssertTrue(history.canGoForward, "staying put keeps forward")
        history.go(to: general)
        XCTAssertFalse(history.canGoForward)
    }
}
