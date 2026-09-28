import XCTest

@testable import AgentSDK

final class PermissionUpdateTests: XCTestCase {
    private func roundTrip(_ update: PermissionUpdate) throws -> PermissionUpdate {
        try JSONDecoder().decode(PermissionUpdate.self, from: JSONEncoder().encode(update))
    }

    func testKnownKindsRoundTrip() throws {
        let updates: [PermissionUpdate] = [
            .addRules(
                [PermissionRule(toolName: "Bash", ruleContent: "git status:*")], behavior: .allow,
                destination: .localSettings),
            .replaceRules([PermissionRule(toolName: "Read")], behavior: .deny, destination: .session),
            .removeRules([], behavior: .ask, destination: .userSettings),
            .setMode(.acceptEdits, destination: .session),
            .addDirectories(["/tmp"], destination: .projectSettings),
            .removeDirectories(["/tmp"], destination: PermissionUpdate.Destination(rawValue: "futureStore")),
        ]
        for update in updates {
            XCTAssertEqual(try roundTrip(update), update)
        }
    }

    func testWireShape() {
        let update = PermissionUpdate.addRules(
            [PermissionRule(toolName: "Bash", ruleContent: "ls")], behavior: .allow, destination: .session)
        XCTAssertEqual(
            update.jsonValue,
            [
                "type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "ls"]], "behavior": "allow",
                "destination": "session",
            ])
    }

    func testUnknownOrMalformedIsKeptVerbatim() throws {
        let values: [JSONValue] = [
            ["type": "grantEverything", "destination": "session"],
            ["type": "setMode", "mode": "yolo", "destination": "session"],
            ["type": "addRules", "rules": "Bash", "behavior": "allow", "destination": "session"],
        ]
        for value in values {
            let update = try value.decode(PermissionUpdate.self)
            XCTAssertEqual(update, .unknown(value))
            XCTAssertEqual(update.jsonValue, value)
        }
    }
}
