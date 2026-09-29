import XCTest

@testable import AgentSDK

/// ``AuthStatus`` decoding and the sign-in URL read from `claude auth login`.
/// The shapes follow the CLI's real output; the values are synthetic.
final class AuthTests: XCTestCase {
    func testSignedInStatusDecodes() throws {
        let json = """
            {
              "loggedIn": true,
              "authMethod": "claude.ai",
              "apiProvider": "firstParty",
              "analyticsDisabled": false,
              "projectsDirectory": "/Users/me/.claude/projects",
              "configDirectory": "/Users/me/.claude",
              "email": "name@example.com",
              "orgId": "00000000-0000-0000-0000-000000000000",
              "orgName": "Personal",
              "subscriptionType": "max"
            }
            """
        let status = try JSONDecoder().decode(AuthStatus.self, from: Data(json.utf8))
        XCTAssertEqual(
            status,
            AuthStatus(
                isLoggedIn: true, authMethod: "claude.ai", apiProvider: "firstParty", email: "name@example.com",
                organizationID: "00000000-0000-0000-0000-000000000000", organizationName: "Personal",
                subscriptionType: "max"))
    }

    func testSignedOutStatusDecodes() throws {
        let json = """
            {"loggedIn": false, "authMethod": "none", "apiProvider": "firstParty", "analyticsDisabled": false}
            """
        let status = try JSONDecoder().decode(AuthStatus.self, from: Data(json.utf8))
        XCTAssertFalse(status.isLoggedIn)
        XCTAssertEqual(status.authMethod, "none")
        XCTAssertNil(status.email)
    }

    func testMalformedOptionalFieldDecodesAsNil() throws {
        let status = try JSONDecoder().decode(
            AuthStatus.self, from: Data(#"{"loggedIn": true, "email": 7, "subscriptionType": ["max"]}"#.utf8))
        XCTAssertTrue(status.isLoggedIn)
        XCTAssertNil(status.email)
        XCTAssertNil(status.subscriptionType)
    }

    /// The URL comes wrapped in a terminal hyperlink: `ESC ] 8 ; ; url BEL
    /// url ESC ] 8 ; ; BEL`.
    func testBrowserURLStopsAtTheHyperlinkEscape() {
        let url = "https://claude.com/cai/oauth/authorize?code=true&state=abc_123"
        let text =
            "Opening browser to sign in…\nIf the browser didn't open, visit: \u{1b}]8;;\(url)\u{07}\(url)\u{1b}]8;;\u{07}\nPaste code here if prompted > "
        XCTAssertEqual(Auth.browserURL(in: text), URL(string: url))
        XCTAssertNil(Auth.browserURL(in: "Opening browser to sign in…\n"))
    }
}
