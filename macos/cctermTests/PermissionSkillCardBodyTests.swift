import AgentSDK
import Foundation
import XCTest

@testable import ccterm

/// Logic tests for the Skill body's input extraction: `skill`,
/// optional `args`, and the cwd basename chip. The cwd field is
/// process-derived rather than input-derived, so the chip test just
/// pins that the basename comes from `FileManager.default
/// .currentDirectoryPath` — the per-cwd scope is exactly what
/// upstream's "Allow always for X in <cwd>" branch would install.
final class PermissionSkillCardBodyTests: XCTestCase {

    func testSkillDrivesHeadline() {
        let body = makeBody(input: ["skill": "commit"])
        XCTAssertEqual(body.skill, "commit")
        let skillName = "commit"
        XCTAssertEqual(
            body.headline, String(localized: "Use skill \"\(skillName)\""))
    }

    func testHeadlineFallsBackWhenSkillOmitted() {
        let body = makeBody(input: [:])
        XCTAssertNil(body.skill)
        XCTAssertEqual(body.headline, String(localized: "Use skill"))
    }

    func testCamelCaseSkillNameIsAccepted() {
        let body = makeBody(input: ["skillName": "review-pr"])
        XCTAssertEqual(body.skill, "review-pr")
    }

    func testArgsAreSurfacedWhenPresent() {
        let body = makeBody(input: [
            "skill": "review-pr", "args": "--no-confirm 123",
        ])
        XCTAssertEqual(body.args, "--no-confirm 123")
    }

    func testEmptyArgsAreNil() {
        let body = makeBody(input: ["skill": "pdf", "args": ""])
        XCTAssertNil(body.args)
    }

    func testCwdLabelIsBasename() {
        // The chip's value tracks `FileManager.currentDirectoryPath`
        // — assert via the same source so the test isn't pinned to
        // a specific repo layout.
        let body = makeBody(input: ["skill": "commit"])
        let expected = (FileManager.default.currentDirectoryPath as NSString)
            .lastPathComponent
        XCTAssertEqual(body.cwdLabel, expected.isEmpty ? nil : expected)
    }

    // MARK: - Helpers

    private func makeBody(input: [String: Any]) -> PermissionSkillCardBody {
        let req = PermissionRequest.makePreview(
            requestId: "skill-\(UUID().uuidString)",
            toolName: "Skill",
            input: input)
        return PermissionSkillCardBody(request: req)
    }
}
