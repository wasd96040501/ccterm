import XCTest

@testable import ccterm

/// Back and forward through the Settings panes, and which launch command wins.
final class SettingsHistoryTests: XCTestCase {
    func testBackAndForwardWalkThePanesVisited() {
        var history = SettingsHistory(.accounts)
        XCTAssertFalse(history.canGoBack)
        history.go(to: .general)
        XCTAssertEqual(history.current, .general)
        XCTAssertTrue(history.canGoBack)
        history.goBack()
        XCTAssertEqual(history.current, .accounts)
        XCTAssertTrue(history.canGoForward)
        history.goForward()
        XCTAssertEqual(history.current, .general)
        XCTAssertFalse(history.canGoForward)
    }

    func testGoingSomewhereNewDropsForwardAndStayingPutRecordsNothing() {
        var history = SettingsHistory(.accounts)
        history.go(to: .general)
        history.goBack()
        history.go(to: .accounts)
        XCTAssertTrue(history.canGoForward, "staying put keeps forward")
        history.go(to: .general)
        XCTAssertFalse(history.canGoForward)
    }

    func testAnAccountsCommandWinsOverTheOneInGeneral() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let launch = LaunchSettings(defaults: defaults, locate: { nil })
        var account = Account.newProvider()
        XCTAssertNil(launch.command(for: account))
        launch.command = "  orange  "
        XCTAssertEqual(launch.command, "orange")
        XCTAssertEqual(launch.command(for: account), "orange")
        account.command = "relay-wrapper"
        XCTAssertEqual(launch.command(for: account), "relay-wrapper")
        launch.command = ""
        XCTAssertNil(defaults.object(forKey: "customCLICommand"))
    }
}
